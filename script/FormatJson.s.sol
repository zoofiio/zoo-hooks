// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title FormatJson
 * @notice A utility script to format JSON deployment files
 */
contract FormatJson is Script {
    // Gets the path to a deployment file
    function getDeploymentPath(string memory network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", network, ".json"));
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
    
    function run() public {
        // First format sepolia.json
        string memory network = "sepolia";
        string memory deploymentPath = getDeploymentPath(network);
        
        string memory json;
        try vm.readFile(deploymentPath) returns (string memory content) {
            json = content;
            
            // Format the JSON
            string memory formatted = formatJson(json);
            
            // Write back the formatted JSON
            vm.writeFile(deploymentPath, formatted);
            console.log("Formatted %s successfully", deploymentPath);
        } catch {
            console.log("Could not read %s", deploymentPath);
        }
        
        // Also format latest.json
        try vm.readFile("./deployments/latest.json") returns (string memory content) {
            json = content;
            
            // Format the JSON
            string memory formatted = formatJson(json);
            
            // Write back the formatted JSON
            vm.writeFile("./deployments/latest.json", formatted);
            console.log("Formatted deployments/latest.json successfully");
        } catch {
            console.log("Could not read latest.json");
        }
    }
}
