// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Create2} from "openzeppelin/utils/Create2.sol";

/**
 * @title AddressGenerator
 * @notice Helper contract to generate predictable addresses using CREATE2
 * @dev Used to ensure SY address is smaller than PT address
 */
contract AddressGenerator {
    /**
     * @notice Compute address for a contract deployed using CREATE2
     * @param salt Salt value used for the deployment
     * @param bytecodeHash Hash of the contract bytecode
     * @return The computed address
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) public view returns (address) {
        return Create2.computeAddress(salt, bytecodeHash);
    }
    
    /**
     * @notice Find a salt that makes SY address smaller than PT address
     * @param syBytecodeHash Hash of the SY token contract bytecode
     * @param ptBytecodeHash Hash of the PT token contract bytecode
     * @return sySalt Salt to use for SY deployment
     * @return ptSalt Salt to use for PT deployment
     */
    function findAddressOrderingSalts(bytes32 syBytecodeHash, bytes32 ptBytecodeHash) 
        public 
        view 
        returns (bytes32 sySalt, bytes32 ptSalt) 
    {
        // Start with different base salts
        sySalt = bytes32(uint256(0x1));
        ptSalt = bytes32(uint256(0x2));
        
        // Try up to 100 times to find suitable salts
        for (uint256 i = 0; i < 100; i++) {
            address syAddr = computeAddress(sySalt, syBytecodeHash);
            address ptAddr = computeAddress(ptSalt, ptBytecodeHash);
            
            if (syAddr < ptAddr) {
                // Found suitable salts
                return (sySalt, ptSalt);
            }
            
            // Increment salts and try again
            sySalt = bytes32(uint256(sySalt) + 2);
            ptSalt = bytes32(uint256(ptSalt) + 2);
        }
        
        // If we reach here, we've tried 100 combinations without success
        // This is extremely unlikely, but we revert to be safe
        revert("Could not find suitable salts");
    }
    
    /**
     * @notice Deploy a contract to a predetermined address
     * @param salt Salt for deployment
     * @param bytecode Contract bytecode
     */
    function deploy(bytes32 salt, bytes memory bytecode) public returns (address addr) {
        addr = Create2.deploy(0, salt, bytecode);
    }
}
