// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title InitDeployments
 * @dev Initialize the deployments directory and create an empty template file if needed
 */
contract InitDeployments is Script {
    function run() public {
        // Create deployments directory if it doesn't exist
        string[] memory mkdirCmd = new string[](3);
        mkdirCmd[0] = "mkdir";
        mkdirCmd[1] = "-p";
        mkdirCmd[2] = "./deployments";
        
        vm.ffi(mkdirCmd);
        
        // Try to read sepolia.json
        try vm.readFile("./deployments/sepolia.json") returns (string memory json) {
            // If file exists but is empty or has invalid JSON, replace it
            if (bytes(json).length == 0) {
                vm.writeFile("./deployments/sepolia.json", "{}");
                console.log("Created empty sepolia.json file");
            } else {
                console.log("sepolia.json already exists with content");
            }
        } catch {
            // Create an empty JSON object template
            vm.writeFile("./deployments/sepolia.json", "{}");
            console.log("Created empty sepolia.json file");
        }
        
        // Try to read latest.json
        try vm.readFile("./deployments/latest.json") returns (string memory json) {
            if (bytes(json).length == 0) {
                vm.writeFile("./deployments/latest.json", "{}");
                console.log("Created empty latest.json file");
            } else {
                console.log("latest.json already exists with content");
            }
        } catch {
            vm.writeFile("./deployments/latest.json", "{}");
            console.log("Created empty latest.json file");
        }
    }
}
