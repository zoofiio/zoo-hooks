// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";  // Change back to regular console
import {stdJson} from "forge-std/StdJson.sol";

contract Verify is Script {
    using stdJson for string;

    function getChainId(string memory network) internal pure returns (string memory) {
        if (keccak256(bytes(network)) == keccak256(bytes("mainnet"))) return "1";
        if (keccak256(bytes(network)) == keccak256(bytes("sepolia"))) return "11155111";
        if (keccak256(bytes(network)) == keccak256(bytes("base"))) return "8453";
        if (keccak256(bytes(network)) == keccak256(bytes("basegoerli"))) return "84531";
        return "11155111"; // Default to sepolia
    }

    // Network-specific deployment file path
    function getDeploymentPath(string memory _network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", _network, ".json"));
    }

    function run() view public {
        // Get network from env or use sepolia as default
        string memory network = vm.envOr("NETWORK", string("sepolia"));
        string memory deploymentPath = getDeploymentPath(network);
        
        // Try to read deployment file for the specified network
        string memory deploymentJson;
        try vm.readFile(deploymentPath) returns (string memory json) {
            deploymentJson = json;
        } catch {
            // Fall back to latest.json if network-specific file doesn't exist
            deploymentJson = vm.readFile("./deployments/latest.json");
        }
        
        // Get chain ID
        string memory chainId = getChainId(network);
        
        // Extract contract addresses and constructor args using proper stdJson parsing
        bytes memory protocolRaw = stdJson.parseRaw(deploymentJson, ".Protocol.address");
        bytes memory syTokenRaw = stdJson.parseRaw(deploymentJson, ".StandardYieldToken.address");
        bytes memory ptTokenRaw = stdJson.parseRaw(deploymentJson, ".PrincipalToken.address");
        bytes memory hookRaw = stdJson.parseRaw(deploymentJson, ".YieldSwapHook.address");
        
        address protocol = abi.decode(protocolRaw, (address));
        address syToken = abi.decode(syTokenRaw, (address));
        address ptToken = abi.decode(ptTokenRaw, (address));
        address hook = abi.decode(hookRaw, (address));
        
        // Extract contracts and args using proper stdJson parsing
        string memory syContract = string(stdJson.parseRaw(deploymentJson, ".StandardYieldToken.contract"));
        string memory ptContract = string(stdJson.parseRaw(deploymentJson, ".PrincipalToken.contract"));
        string memory hookContract = string(stdJson.parseRaw(deploymentJson, ".YieldSwapHook.contract"));
        
        // Get hook args - need to handle JSON array parsing properly
        bytes memory hookArgsRaw = stdJson.parseRaw(deploymentJson, ".YieldSwapHook.args");
        string[] memory hookArgs = abi.decode(hookArgsRaw, (string[]));
        
        address poolManager = address(0);
        uint256 epochStart = 0;
        uint256 epochDuration = 0;
        
        if (hookArgs.length >= 4) {
            poolManager = abi.decode(bytes(hookArgs[1]), (address));
            epochStart = abi.decode(bytes(hookArgs[2]), (uint256));
            epochDuration = abi.decode(bytes(hookArgs[3]), (uint256));
        }
        
        // Output verification commands
        console.log("=== Verification Commands for %s (Chain ID: %s) ===", network, chainId);
        
        console.log("\n# Verify Protocol contract");
        console.log("forge verify-contract \\");
        console.log("  --chain-id %s \\", chainId);
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \"constructor()\") \\");
        console.log("  %s \\", vm.toString(protocol));
        console.log("  src/Protocol.sol:Protocol");
        
        console.log("\n# Verify SY Token contract");
        console.log("forge verify-contract \\");
        console.log("  --chain-id %s \\", chainId);
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" %s) \\", vm.toString(protocol));
        console.log("  %s \\", vm.toString(syToken));
        console.log("  %s", syContract);
        
        console.log("\n# Verify PT Token contract");
        console.log("forge verify-contract \\");
        console.log("  --chain-id %s \\", chainId);
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" %s) \\", vm.toString(protocol));
        console.log("  %s \\", vm.toString(ptToken));
        console.log("  %s", ptContract);
        
        console.log("\n# Verify YieldSwapHook contract");
        console.log("forge verify-contract \\");
        console.log("  --chain-id %s \\", chainId);
        console.log("  --watch \\");
        
        // Split the complex constructor args into multiple parts
        string memory protocolArg = vm.toString(protocol);
        string memory poolManagerArg = vm.toString(poolManager);
        string memory epochStartArg = vm.toString(epochStart);
        string memory epochDurationArg = vm.toString(epochDuration);
        
        // Build the command string in multiple steps
        console.log("  --constructor-args $(cast abi-encode \"constructor(address,address,uint256,uint256)\" \\");
        console.log("    %s \\", protocolArg);
        console.log("    %s \\", poolManagerArg);
        console.log("    %s \\", epochStartArg);
        console.log("    %s) \\", epochDurationArg);
        console.log("  %s \\", vm.toString(hook));
        console.log("  %s", hookContract);
        
        console.log("\n=== End of Verification Commands ===");
    }
}
