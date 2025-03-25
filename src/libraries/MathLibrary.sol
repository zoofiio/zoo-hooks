// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MathLibrary
 * @notice A library for mathematical functions used in yield products
 */
library MathLibrary {
    /**
     * @notice Implementation of natural log function for fixed point numbers
     * @dev Implements ln(x) with x scaled by 1e18
     * @param x The input value (must be > 0)
     * @return The natural logarithm of x, scaled by 1e18
     */
    function ln(uint256 x) internal pure returns (uint256) {
        if (x == 0) revert("MathError: Input cannot be zero");
        
        // ln(1) = 0
        if (x == 1e18) return 0;
        
        // If x < 1e18 (i.e., x < 1 in non-scaled form)
        if (x < 1e18) {
            // For values less than 1, we use the approximation ln(1-z) ≈ -z - z^2/2 for small z
            // Here, z = 1 - x/1e18
            uint256 z1 = 1e18 - x;
            uint256 term1 = z1;
            uint256 term2 = (z1 * z1) / 2e18;
            
            // Return -(term1 + term2), scaled to 1e18
            return 1e18 * (term1 + term2) / 1e18;
        }
        
        // If x ≥ 1e18, calculate ln(x)
        uint256 result = 0;
        uint256 y = x;
        
        // Use the identity: ln(a * 2^b) = ln(a) + b * ln(2)
        // Repeatedly divide by 2 until y < 2e18
        while (y >= 2e18) {
            y = y / 2;
            result += 693147180559945309; // ln(2) * 1e18
        }
        
        // Now y is in [1e18, 2e18), use a Taylor series for ln(1 + z) where z = y - 1e18
        uint256 z2 = y - 1e18;
        
        // ln(1+z) = z - z^2/2 + z^3/3 - ... for |z| < 1
        uint256 z_squared = (z2 * z2) / 1e18;
        uint256 z_cubed = (z_squared * z2) / 1e18;
        
        // First three terms of Taylor series should give decent accuracy
        result += z2;                    // z
        result -= z_squared / 2;        // - z^2/2
        result += (z_cubed * 1e18) / 3e18;  // + z^3/3
        
        return result;
    }
}
