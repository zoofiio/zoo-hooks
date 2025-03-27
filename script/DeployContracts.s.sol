// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Protocol} from "src/Protocol.sol";
import {StandardYieldToken} from "src/tokens/StandardYieldToken.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldSwapHook} from "src/YieldSwapHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Create2} from "openzeppelin/utils/Create2.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

contract DeployContracts is Script {
    using stdJson for string;
    
    address constant UNISWAP_V4_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Get Pool Manager address based on network or directly from .env
    function getPoolManagerAddress() internal view returns (address) {
        // First try to get a direct POOL_MANAGER_ADDRESS from .env
        try vm.envAddress("POOL_MANAGER_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            // Fallback to network-based selection
            string memory network = vm.envOr("NETWORK", string("sepolia"));
            
            if (keccak256(bytes(network)) == keccak256(bytes("sepolia"))) {
                return vm.envOr("POOL_MANAGER_SEPOLIA", address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543));
            } else if (keccak256(bytes(network)) == keccak256(bytes("mainnet"))) {
                return vm.envOr("POOL_MANAGER_MAINNET", address(0x000000000004444c5dc75cB358380D2e3dE08A90));
            }
            
            revert("Unsupported network or POOL_MANAGER_ADDRESS not set");
        }
    }
    
    Protocol public protocol;
    StandardYieldToken public syToken;
    PrincipalToken public ptToken;
    YieldSwapHook public hook;
    
    // Hook flags for YieldSwapHook
    address public hookAddress;
    
    // Network-specific deployment file path
    function getDeploymentPath(string memory network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", network, ".json"));
    }
    
    // Check if a contract is already deployed
    function isContractDeployed(string memory network, string memory contractName) internal view returns (bool, address) {
        string memory deploymentPath = getDeploymentPath(network);
        
        // Check if the deployment file exists
        try vm.readFile(deploymentPath) returns (string memory json) {
            // Make sure the JSON is not empty and is valid
            if (bytes(json).length == 0 || keccak256(bytes(json)) == keccak256(bytes("{}"))) {
                return (false, address(0));
            }
            
            // Use vm.parseJson directly - it returns bytes that need to be decoded
            string memory addressPath = string(abi.encodePacked(".", contractName, ".address"));
            
            try vm.parseJson(json, addressPath) returns (bytes memory rawAddress) {
                if (rawAddress.length > 0) {
                    // Convert the bytes to an address
                    address contractAddress = abi.decode(rawAddress, (address));
                    return (true, contractAddress);
                } else {
                    return (false, address(0));
                }
            } catch {
                return (false, address(0));
            }
        } catch {
            // Deployment file doesn't exist or can't be read
            return (false, address(0));
        }
    }
    
    // Format JSON with indentation and line breaks
    function formatJson(string memory jsonStr) internal pure returns (string memory) {
        bytes memory jsonBytes = bytes(jsonStr);
        uint256 indent = 0;
        bool inQuotes = false;
        
        string memory result = "";
        string memory indentStr = "";
        
        for (uint256 i = 0; i < jsonBytes.length; i++) {
            bytes1 char = jsonBytes[i];
            
            // Track whether we're inside quotes
            if (char == '"' && (i == 0 || jsonBytes[i-1] != '\\')) {
                inQuotes = !inQuotes;
            }
            
            // Only apply formatting if outside quotes
            if (!inQuotes) {
                // Handle opening braces
                if (char == '{' || char == '[') {
                    // Add opening brace followed by new line
                    result = string(abi.encodePacked(result, string(abi.encodePacked(char)), "\n"));
                    indent++;
                    indentStr = getIndent(indent);
                    result = string(abi.encodePacked(result, indentStr));
                    continue;
                }
                
                // Handle closing braces
                if (char == '}' || char == ']') {
                    // Add new line and indentation before closing brace
                    result = string(abi.encodePacked(result, "\n"));
                    indent--;
                    indentStr = getIndent(indent);
                    result = string(abi.encodePacked(result, indentStr, string(abi.encodePacked(char))));
                    continue;
                }
                
                // Handle commas
                if (char == ',') {
                    // Add comma followed by new line and indentation
                    result = string(abi.encodePacked(result, string(abi.encodePacked(char)), "\n", indentStr));
                    continue;
                }
                
                // Handle colons
                if (char == ':') {
                    // Add colon followed by a space
                    result = string(abi.encodePacked(result, ": "));
                    continue;
                }
            }
            
            // Add all other characters
            result = string(abi.encodePacked(result, string(abi.encodePacked(char))));
        }
        
        return result;
    }
    
    // Generate indentation string
    function getIndent(uint256 level) internal pure returns (string memory) {
        string memory indent = "";
        for (uint256 i = 0; i < level; i++) {
            indent = string(abi.encodePacked(indent, "  ")); // 2 spaces per level
        }
        return indent;
    }
    
    // Save deployment information to network-specific file
    function saveDeployment(string memory network, string memory contractsJson) internal {
        string memory deploymentPath = getDeploymentPath(network);
        
        // Create directory if it doesn't exist
        string[] memory mkdirCmd = new string[](3);
        mkdirCmd[0] = "mkdir";
        mkdirCmd[1] = "-p";
        mkdirCmd[2] = "./deployments";
        vm.ffi(mkdirCmd);
        
        // Format the JSON before saving
        string memory formattedJson = formatJson(contractsJson);
        
        // Directly write to the file, overwriting any existing content
        vm.writeFile(deploymentPath, formattedJson);
        
        // Also save to latest.json for convenience
        vm.writeFile("./deployments/latest.json", formattedJson);
        
        console.log("\nDeployment info saved to:");
        console.log("- ./deployments/latest.json");
        console.log("- %s", deploymentPath);
    }
    
    function run() public {
        // Load private key from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get network name
        string memory network = vm.envOr("NETWORK", string("sepolia"));
        
        // Get Pool Manager address based on network
        address poolManager = getPoolManagerAddress();
        
        console.log("Deploying contracts to network:", network);
        console.log("Deployer address:", deployer);
        console.log("Pool Manager address:", poolManager);
        
        // Create JSON object to store deployment info - start with an empty object
        string memory deploymentJson = "{}";
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Protocol if not already deployed
        bool deployed;
        address existingAddress;
        (deployed, existingAddress) = isContractDeployed(network, "Protocol");
        
        if (deployed) {
            console.log("Protocol already deployed at:", existingAddress);
            protocol = Protocol(existingAddress);
        } else {
            protocol = new Protocol();
            console.log("Protocol deployed at:", address(protocol));
            
            // Format Protocol contract info correctly as a nested object
            string memory protocolObj = "{";
            protocolObj = string(abi.encodePacked(protocolObj, "\"address\":\"", vm.toString(address(protocol)), "\","));
            protocolObj = string(abi.encodePacked(protocolObj, "\"contract\":\"src/Protocol.sol:Protocol\","));
            protocolObj = string(abi.encodePacked(protocolObj, "\"args\":[]"));
            protocolObj = string(abi.encodePacked(protocolObj, "}"));
            
            // Build JSON manually instead of using vm.writeJson
            deploymentJson = string(abi.encodePacked("{\"Protocol\":", protocolObj));
        }
        
        // Deploy StandardYieldToken (SY)
        (deployed, existingAddress) = isContractDeployed(network, "StandardYieldToken");
        
        if (deployed) {
            console.log("StandardYieldToken already deployed at:", existingAddress);
            syToken = StandardYieldToken(existingAddress);
        } else {
            syToken = new StandardYieldToken(address(protocol));
            console.log("SY Token deployed at:", address(syToken));
            
            // Format StandardYieldToken contract info correctly as a nested object
            string memory syTokenObj = "{";
            syTokenObj = string(abi.encodePacked(syTokenObj, "\"address\":\"", vm.toString(address(syToken)), "\","));
            syTokenObj = string(abi.encodePacked(syTokenObj, "\"contract\":\"src/tokens/StandardYieldToken.sol:StandardYieldToken\","));
            syTokenObj = string(abi.encodePacked(syTokenObj, "\"args\":[\"", vm.toString(address(protocol)), "\"]"));
            syTokenObj = string(abi.encodePacked(syTokenObj, "}"));
            
            // Add to JSON
            if (bytes(deploymentJson).length > 2) { // If not just "{}"
                deploymentJson = string(abi.encodePacked(deploymentJson, ",\"StandardYieldToken\":", syTokenObj));
            } else {
                deploymentJson = string(abi.encodePacked("{\"StandardYieldToken\":", syTokenObj));
            }
        }
        
        // Deploy PrincipalToken (PT)
        (deployed, existingAddress) = isContractDeployed(network, "PrincipalToken");
        
        if (deployed) {
            console.log("PrincipalToken already deployed at:", existingAddress);
            ptToken = PrincipalToken(existingAddress);
        } else {
            ptToken = new PrincipalToken(address(protocol));
            console.log("PT Token deployed at:", address(ptToken));
            
            // Format PrincipalToken contract info correctly as a nested object
            string memory ptTokenObj = "{";
            ptTokenObj = string(abi.encodePacked(ptTokenObj, "\"address\":\"", vm.toString(address(ptToken)), "\","));
            ptTokenObj = string(abi.encodePacked(ptTokenObj, "\"contract\":\"src/tokens/PrincipalToken.sol:PrincipalToken\","));
            ptTokenObj = string(abi.encodePacked(ptTokenObj, "\"args\":[\"", vm.toString(address(protocol)), "\"]"));
            ptTokenObj = string(abi.encodePacked(ptTokenObj, "}"));
            
            // Add to JSON
            if (bytes(deploymentJson).length > 2) { // If not just "{}"
                deploymentJson = string(abi.encodePacked(deploymentJson, ",\"PrincipalToken\":", ptTokenObj));
            } else {
                deploymentJson = string(abi.encodePacked("{\"PrincipalToken\":", ptTokenObj));
            }
        }
        
        // Deploy YieldSwapHook if not already deployed
        (deployed, existingAddress) = isContractDeployed(network, "YieldSwapHook");
        
        if (deployed) {
            console.log("YieldSwapHook already deployed at:", existingAddress);
            hook = YieldSwapHook(existingAddress);
        } else {
            // Set up epoch parameters
            uint256 epochStart = block.timestamp; // Start now
            uint256 epochDuration = 30 days; // 30 day duration
            
            // Define the hook flags we need
            uint160 flags = uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            );
            
            // Mine a salt that will produce a hook address with the correct flags
            bytes memory constructorArgs = abi.encode(
                address(protocol),
                IPoolManager(poolManager),
                epochStart,
                epochDuration
            );

            // Important: Use the standard Uniswap V4 CREATE2 factory address, NOT the deployer address
            (address expectedHookAddress, bytes32 salt) = HookMiner.find(
                UNISWAP_V4_CREATE2_FACTORY,  // Use our renamed constant
                flags,
                type(YieldSwapHook).creationCode,
                constructorArgs
            );
            
            console.log("Mined salt:", uint256(salt));
            console.log("Expected hook address:", expectedHookAddress);
            
            // Get the initialization code with constructor arguments
            bytes memory creationCode = abi.encodePacked(
                type(YieldSwapHook).creationCode,
                constructorArgs
            );

            // Deploy using CREATE2 factory instead of direct CREATE2 opcode
            address deployedHook = Create2.deploy(
                0, // No ETH value needed
                salt,
                creationCode
            );
            
            console.log("Deployed hook address:", deployedHook);
            
            // Verify successful deployment and address match
            require(deployedHook == expectedHookAddress, "Hook address mismatch");
            
            hook = YieldSwapHook(deployedHook);
            console.log("YieldSwapHook deployed at:", address(hook));
            
            // Format YieldSwapHook contract info correctly as a nested object
            string memory hookObj = "{";
            hookObj = string(abi.encodePacked(hookObj, "\"address\":\"", vm.toString(address(hook)), "\","));
            hookObj = string(abi.encodePacked(hookObj, "\"contract\":\"src/YieldSwapHook.sol:YieldSwapHook\","));
            
            // Build args array
            hookObj = string(abi.encodePacked(hookObj, "\"args\":["));
            hookObj = string(abi.encodePacked(hookObj, "\"", vm.toString(address(protocol)), "\","));
            hookObj = string(abi.encodePacked(hookObj, "\"", vm.toString(poolManager), "\","));
            hookObj = string(abi.encodePacked(hookObj, vm.toString(epochStart), ","));
            hookObj = string(abi.encodePacked(hookObj, vm.toString(epochDuration)));
            hookObj = string(abi.encodePacked(hookObj, "]"));
            
            // Add extra metadata for reference
            hookObj = string(abi.encodePacked(hookObj, ",\"metadata\":{"));
            hookObj = string(abi.encodePacked(hookObj, "\"salt\":\"", vm.toString(salt), "\","));
            hookObj = string(abi.encodePacked(hookObj, "\"epochStart\":", vm.toString(epochStart), ","));
            hookObj = string(abi.encodePacked(hookObj, "\"epochDuration\":", vm.toString(epochDuration), ","));
            hookObj = string(abi.encodePacked(hookObj, "\"SCALAR_ROOT\":", vm.toString(hook.SCALAR_ROOT()), ","));
            hookObj = string(abi.encodePacked(hookObj, "\"ANCHOR_ROOT\":\"", vm.toString(hook.ANCHOR_ROOT()), "\","));
            hookObj = string(abi.encodePacked(hookObj, "\"ANCHOR_BASE\":\"", vm.toString(hook.ANCHOR_BASE()), "\","));
            hookObj = string(abi.encodePacked(hookObj, "\"MINIMUM_LIQUIDITY\":", vm.toString(hook.MINIMUM_LIQUIDITY())));
            hookObj = string(abi.encodePacked(hookObj, "}"));
            
            hookObj = string(abi.encodePacked(hookObj, "}"));
            
            // Add to JSON
            if (bytes(deploymentJson).length > 2) { // If not just "{}"
                deploymentJson = string(abi.encodePacked(deploymentJson, ",\"YieldSwapHook\":", hookObj));
            } else {
                deploymentJson = string(abi.encodePacked("{\"YieldSwapHook\":", hookObj));
            }
        }
        
        // Close the JSON object
        deploymentJson = string(abi.encodePacked(deploymentJson, "}"));
        
        // Output deployment summary
        console.log("\nDeployment Summary:");
        console.log("Protocol:", address(protocol));
        console.log("SY Token:", address(syToken));
        console.log("PT Token:", address(ptToken));
        console.log("YieldSwapHook:", address(hook));
        
        vm.stopBroadcast();
        
        // Save deployment info
        saveDeployment(network, deploymentJson);
    }
}
