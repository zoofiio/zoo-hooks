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
            // Use proper stdJson parsing
            bytes memory rawAddress = stdJson.parseRaw(json, string(abi.encodePacked(".", contractName, ".address")));
            if (rawAddress.length > 0) {
                address contractAddress = abi.decode(rawAddress, (address));
                return (true, contractAddress);
            } else {
                return (false, address(0));
            }
        } catch {
            // Deployment file doesn't exist
            return (false, address(0));
        }
    }
    
    // Save deployment information to network-specific file
    function saveDeployment(string memory network, string memory deploymentJson) internal {
        string memory deploymentPath = getDeploymentPath(network);
        string memory existingJson;
        string memory finalJson;
        
        // Try to read existing deployment file
        try vm.readFile(deploymentPath) returns (string memory json) {
            existingJson = json;
            // Merge with existing JSON
            vm.writeJson(deploymentJson, deploymentPath);
            finalJson = vm.readFile(deploymentPath);
        } catch {
            // File doesn't exist, create it with current deployment
            finalJson = deploymentJson;
            vm.writeFile(deploymentPath, finalJson);
        }
        
        // Also save to latest.json for convenience
        // vm.writeFile("./deployments/latest.json", finalJson);
        
        console.log("\nDeployment info saved to:");
        // console.log("- ./deployments/latest.json");
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
        
        // Create JSON object to store deployment info
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
            
            // Add to deployment JSON - fix writeString usage
            deploymentJson = vm.serializeAddress(deploymentJson, "Protocol.address", address(protocol));
            deploymentJson = vm.serializeString(deploymentJson, "Protocol.contract", "src/Protocol.sol:Protocol");
            
            // Use serializeString instead of writeString
            string memory emptyArgs = "[]";
            deploymentJson = vm.serializeString(deploymentJson, "Protocol.args", emptyArgs);
        }
        
        // Deploy StandardYieldToken (SY)
        (deployed, existingAddress) = isContractDeployed(network, "StandardYieldToken");
        
        if (deployed) {
            console.log("StandardYieldToken already deployed at:", existingAddress);
            syToken = StandardYieldToken(existingAddress);
        } else {
            syToken = new StandardYieldToken(address(protocol));
            console.log("SY Token deployed at:", address(syToken));
            
            // Add to deployment JSON
            deploymentJson = vm.serializeAddress(deploymentJson, "StandardYieldToken.address", address(syToken));
            deploymentJson = vm.serializeString(
                deploymentJson, 
                "StandardYieldToken.contract", 
                "src/tokens/StandardYieldToken.sol:StandardYieldToken"
            );
            
            // Fix array serialization
            string memory syArgs = "[";
            syArgs = string(abi.encodePacked(syArgs, "\"", vm.toString(address(protocol)), "\""));
            syArgs = string(abi.encodePacked(syArgs, "]"));
            deploymentJson = vm.serializeString(deploymentJson, "StandardYieldToken.args", syArgs);
        }
        
        // Deploy PrincipalToken (PT)
        (deployed, existingAddress) = isContractDeployed(network, "PrincipalToken");
        
        if (deployed) {
            console.log("PrincipalToken already deployed at:", existingAddress);
            ptToken = PrincipalToken(existingAddress);
        } else {
            ptToken = new PrincipalToken(address(protocol));
            console.log("PT Token deployed at:", address(ptToken));
            
            // Add to deployment JSON
            deploymentJson = vm.serializeAddress(deploymentJson, "PrincipalToken.address", address(ptToken));
            deploymentJson = vm.serializeString(
                deploymentJson, 
                "PrincipalToken.contract", 
                "src/tokens/PrincipalToken.sol:PrincipalToken"
            );
            
            // Fix array serialization
            string memory ptArgs = "[";
            ptArgs = string(abi.encodePacked(ptArgs, "\"", vm.toString(address(protocol)), "\""));
            ptArgs = string(abi.encodePacked(ptArgs, "]"));
            deploymentJson = vm.serializeString(deploymentJson, "PrincipalToken.args", ptArgs);
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
            
            // Add to deployment JSON
            deploymentJson = vm.serializeAddress(deploymentJson, "YieldSwapHook.address", address(hook));
            deploymentJson = vm.serializeString(
                deploymentJson, 
                "YieldSwapHook.contract", 
                "src/YieldSwapHook.sol:YieldSwapHook"
            );
            
            // Fix array serialization 
            string memory hookArgs = "[";
            hookArgs = string(abi.encodePacked(hookArgs, "\"", vm.toString(address(protocol)), "\","));
            hookArgs = string(abi.encodePacked(hookArgs, "\"", vm.toString(poolManager), "\","));
            hookArgs = string(abi.encodePacked(hookArgs, vm.toString(epochStart), ","));
            hookArgs = string(abi.encodePacked(hookArgs, vm.toString(epochDuration)));
            hookArgs = string(abi.encodePacked(hookArgs, "]"));
            deploymentJson = vm.serializeString(deploymentJson, "YieldSwapHook.args", hookArgs);
            
            // Add the hook parameters for reference
            deploymentJson = vm.serializeUint(deploymentJson, "YieldSwapHook.epochStart", epochStart);
            deploymentJson = vm.serializeUint(deploymentJson, "YieldSwapHook.epochDuration", epochDuration);
            deploymentJson = vm.serializeUint(deploymentJson, "YieldSwapHook.SCALAR_ROOT", hook.SCALAR_ROOT());
            deploymentJson = vm.serializeInt(deploymentJson, "YieldSwapHook.ANCHOR_ROOT", hook.ANCHOR_ROOT());
            deploymentJson = vm.serializeInt(deploymentJson, "YieldSwapHook.ANCHOR_BASE", hook.ANCHOR_BASE());
            deploymentJson = vm.serializeUint(deploymentJson, "YieldSwapHook.MINIMUM_LIQUIDITY", hook.MINIMUM_LIQUIDITY());
            deploymentJson = vm.serializeBytes32(deploymentJson, "YieldSwapHook.salt", salt);
        }
        
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
