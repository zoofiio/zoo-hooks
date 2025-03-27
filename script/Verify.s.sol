// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title Verify
 * @notice A script to generate and output verification commands for deployed contracts
 * @dev Run with: forge script script/Verify.s.sol --rpc-url <network>
 */
contract Verify is Script {
    using stdJson for string;

    // Network-specific deployment file path
    function getDeploymentPath(string memory network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", network, ".json"));
    }
    
    function getChainId(string memory network) internal pure returns (string memory) {
        if (keccak256(bytes(network)) == keccak256(bytes("mainnet"))) return "1";
        if (keccak256(bytes(network)) == keccak256(bytes("sepolia"))) return "11155111";
        if (keccak256(bytes(network)) == keccak256(bytes("base"))) return "8453";
        if (keccak256(bytes(network)) == keccak256(bytes("basegoerli"))) return "84531";
        if (keccak256(bytes(network)) == keccak256(bytes("arbitrum"))) return "42161"; 
        return "11155111"; // Default to sepolia
    }

    function run() public {
        // Get network name
        string memory network = vm.envOr("NETWORK", string("sepolia"));
        string memory deploymentPath = getDeploymentPath(network);
        string memory chainId = getChainId(network);
        
        // Try to read deployment file
        string memory deploymentJson;
        try vm.readFile(deploymentPath) returns (string memory json) {
            deploymentJson = json;
        } catch {
            revert(string(abi.encodePacked("Failed to read deployment file: ", deploymentPath)));
        }
        
        console.log("\n=== Verification Commands for %s Network ===\n", network);
        
        // Get Protocol address and verify command
        try vm.parseJson(deploymentJson, ".Protocol.address") returns (bytes memory rawAddress) {
            address protocolAddress = abi.decode(rawAddress, (address));
            console.log("### Protocol Contract");
            console.log("Address: %s", protocolAddress);
            console.log("Command:");
            console.log("forge verify-contract --chain %s %s src/Protocol.sol:Protocol", chainId, protocolAddress);
            console.log("");
        } catch {
            console.log("Protocol contract not found in deployment file");
        }
        
        // Get StandardYieldToken address and verify command
        try vm.parseJson(deploymentJson, ".StandardYieldToken.address") returns (bytes memory rawAddress) {
            address syTokenAddress = abi.decode(rawAddress, (address));
            
            string memory syTokenContract;
            try vm.parseJson(deploymentJson, ".StandardYieldToken.contract") returns (bytes memory rawContract) {
                syTokenContract = abi.decode(rawContract, (string));
            } catch {
                syTokenContract = "src/tokens/StandardYieldToken.sol:StandardYieldToken";
            }
            
            console.log("### StandardYieldToken Contract");
            console.log("Address: %s", syTokenAddress);
            
            // Get constructor args for StandardYieldToken (usually Protocol address)
            try vm.parseJson(deploymentJson, ".Protocol.address") returns (bytes memory rawProtocolAddr) {
                address protocolAddress = abi.decode(rawProtocolAddr, (address));
                
                console.log("Command:");
                // Output command parts separately
                console.log("forge verify-contract");
                console.log("--chain %s", chainId);
                console.log("%s", syTokenAddress);
                console.log("%s", syTokenContract);
                console.log("--constructor-args");
                console.log("$(cast abi-encode \"constructor(address)\" %s)", protocolAddress);
                console.log("--etherscan-api-key $ETHERSCAN_API_KEY_ARBITRUM");
                console.log("");
            } catch {
                console.log("Warning: Protocol address not found for constructor args");
            }
        } catch {
            console.log("StandardYieldToken contract not found in deployment file");
        }
        
        // Get PrincipalToken address and verify command
        try vm.parseJson(deploymentJson, ".PrincipalToken.address") returns (bytes memory rawAddress) {
            address ptTokenAddress = abi.decode(rawAddress, (address));
            
            string memory ptTokenContract;
            try vm.parseJson(deploymentJson, ".PrincipalToken.contract") returns (bytes memory rawContract) {
                ptTokenContract = abi.decode(rawContract, (string));
            } catch {
                ptTokenContract = "src/tokens/PrincipalToken.sol:PrincipalToken";
            }
            
            console.log("### PrincipalToken Contract");
            console.log("Address: %s", ptTokenAddress);
            
            // Get constructor args for PrincipalToken (usually Protocol address)
            try vm.parseJson(deploymentJson, ".Protocol.address") returns (bytes memory rawProtocolAddr) {
                address protocolAddress = abi.decode(rawProtocolAddr, (address));
                
                console.log("Command:");
                // Output command parts separately
                console.log("forge verify-contract");
                console.log("--chain %s", chainId);
                console.log("%s", ptTokenAddress);
                console.log("%s", ptTokenContract);
                console.log("--constructor-args");
                console.log("$(cast abi-encode \"constructor(address)\" %s)", protocolAddress);
                console.log("--etherscan-api-key $ETHERSCAN_API_KEY_ARBITRUM");
                console.log("");
            } catch {
                console.log("Warning: Protocol address not found for constructor args");
            }
        } catch {
            console.log("PrincipalToken contract not found in deployment file");
        }
        
        // Get YieldSwapHook address and verify command
        try vm.parseJson(deploymentJson, ".YieldSwapHook.address") returns (bytes memory rawAddress) {
            address hookAddress = abi.decode(rawAddress, (address));
            
            string memory hookContract;
            try vm.parseJson(deploymentJson, ".YieldSwapHook.contract") returns (bytes memory rawContract) {
                hookContract = abi.decode(rawContract, (string));
            } catch {
                hookContract = "src/YieldSwapHook.sol:YieldSwapHook";
            }
            
            console.log("### YieldSwapHook Contract");
            console.log("Address: %s", hookAddress);
            
            // Get full constructor args from metadata
            try vm.parseJson(deploymentJson, ".YieldSwapHook.args") returns (bytes memory rawArgs) {
                // For YieldSwapHook we need to manually format the args
                // Expected format: address protocol, address poolManager, uint256 epochStart, uint256 epochDuration
                address[] memory args = abi.decode(rawArgs, (address[]));
                
                // For YieldSwapHook, also split the complex command
                if (args.length >= 4) {
                    address protocol = args[0];
                    address poolManager = args[1];
                    uint256 epochStart = uint256(uint160(args[2]));
                    uint256 epochDuration = uint256(uint160(args[3]));
                    
                    console.log("Command:");
                    console.log("forge verify-contract");
                    console.log("--chain %s", chainId);
                    console.log("%s", hookAddress);
                    console.log("%s", hookContract);
                    console.log("--constructor-args");
                    console.log("\"$(cast abi-encode \"constructor(address,address,uint256,uint256)\"");
                    console.log("%s", protocol);
                    console.log("%s", poolManager);
                    console.log("%s", epochStart);
                    console.log("%s)\"", epochDuration);
                    console.log("--etherscan-api-key $ETHERSCAN_API_KEY_ARBITRUM");
                    console.log("");
                } else {
                    // Try to get individual metadata values if full args array is not available
                    console.log("WARNING: Complete constructor args not found. Attempting to build from metadata...");
                    
                    try vm.parseJson(deploymentJson, ".Protocol.address") returns (bytes memory rawProtocolAddr) {
                        address protocol = abi.decode(rawProtocolAddr, (address));
                        
                        try vm.parseJson(deploymentJson, ".YieldSwapHook.metadata.epochStart") returns (bytes memory rawEpochStart) {
                            uint256 epochStart = abi.decode(rawEpochStart, (uint256));
                            
                            try vm.parseJson(deploymentJson, ".YieldSwapHook.metadata.epochDuration") returns (bytes memory rawEpochDuration) {
                                uint256 epochDuration = abi.decode(rawEpochDuration, (uint256));
                                
                                console.log("Command (partial args - missing poolManager):");
                                console.log("# Replace <POOL_MANAGER> with the actual poolManager address");
                                console.log("forge verify-contract");
                                console.log("--chain %s", chainId);
                                console.log("%s", hookAddress);
                                console.log("%s", hookContract);
                                console.log("--constructor-args");
                                console.log("\"$(cast abi-encode \"constructor(address,address,uint256,uint256)\"");
                                console.log("%s", protocol);
                                console.log("<POOL_MANAGER>");
                                console.log("%s", epochStart);
                                console.log("%s)\"", epochDuration);
                                console.log("--etherscan-api-key $ETHERSCAN_API_KEY_ARBITRUM");
                                console.log("");
                            } catch {
                                console.log("ERROR: Could not find epochDuration in metadata");
                            }
                        } catch {
                            console.log("ERROR: Could not find epochStart in metadata");
                        }
                    } catch {
                        console.log("ERROR: Could not find protocol address");
                    }
                }
            } catch {
                console.log("ERROR: Could not parse constructor args for YieldSwapHook");
            }
        } catch {
            console.log("YieldSwapHook contract not found in deployment file");
        }
        
        console.log("\n=== End of Verification Commands ===\n");
        console.log("Run these commands to verify contracts on explorers.");
        console.log("For Etherscan-compatible explorers, you need to set the appropriate API key.");
        console.log("Example: export ETHERSCAN_API_KEY=your_api_key");
        console.log("For Arbiscan: export ARBISCAN_API_KEY=your_api_key");
    }
}
