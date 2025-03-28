// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MathLibrary} from "src/libraries/MathLibrary.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ZooCustomCurve} from "src/base/ZooCustomCurve.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/**
 * @title YieldSwapHook
 * @notice A custom AMM Hook for yield products based on Uniswap V4
 * @dev Provides custom pricing logic for SY and PT tokens
 */
contract YieldSwapHook is ProtocolOwner, ZooCustomCurve, ERC20 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency; // Add this line to enable take() and settle() methods
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    
    // Epoch parameters
    uint256 public epochStart;    // Epoch start time in seconds
    uint256 public epochDuration; // Epoch duration in seconds
    
    // Constants for rate calculations
    uint256 public constant SCALAR_ROOT = 200;       // Base value for rateScalar
    int256 public constant ANCHOR_ROOT = 1.2e18;     // Base value for rateAnchor (1.2 with 18 decimals)
    int256 public constant ANCHOR_BASE = 1e18;       // Base value (1.0 with 18 decimals)
    
    // Track reserves manually
    uint256 public reserveSY;    // Reserve of SY tokens (token0)
    uint256 public reservePT;    // Reserve of PT tokens (token1)
    
    // Minimum liquidity constant (Uniswap V2 style)
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Error declarations
    error InvalidHookConfiguration();
    error MathError();
    error InsufficientPTReserves();
    error InsufficientSYReserves();
    error InsufficientLiquidity();
    error InvalidEpochParameters();
    
    event ParametersUpdated(uint256 epochStart, uint256 epochDuration);
    event ReservesUpdated(uint256 reserveSY, uint256 reservePT);
    
    constructor(address _protocol, IPoolManager _poolManager, uint256 _epochStart, uint256 _epochDuration) 
        ProtocolOwner(_protocol)
        ZooCustomCurve(_poolManager) 
        ERC20("YieldSwap Liquidity", "YSL") 
    {
        // Validate and set epoch parameters
        if (_epochDuration == 0) revert InvalidEpochParameters();
        epochStart = _epochStart;
        epochDuration = _epochDuration;
        
        // Reserves start at 0
        reserveSY = 0;
        reservePT = 0;
    }
    
    /**
     * @notice Calculate current time factor and rate parameters
     * @dev Time factor t: linear from 1 at epochStart to 0 after epochDuration
     * @return t Current time factor (between 0 and 1e18)
     */
    function getCurrentTimeFactor() public view returns (uint256 t) {
        uint256 currentTime = block.timestamp;
        
        if (currentTime <= epochStart) {
            // Before or at epoch start, t = 1
            t = 1e18; // Use 18 decimals for precision
        } else if (currentTime >= epochStart + epochDuration) {
            // After epoch end, t = 0
            t = 0;
        } else {
            // During epoch, linearly decrease from 1 to 0
            uint256 timeElapsed = currentTime - epochStart;
            // Use FullMath.mulDiv for safer arithmetic
            t = FullMath.mulDiv(epochDuration - timeElapsed, 1e18, epochDuration);
        }
        
        return t;
    }

    /**
     * @notice Helper function to calculate price using the optimized formula
     * @dev Price_SY = (t / SCALAR_ROOT) * ln(Portion_PT / (1 - Portion_PT)) + (ANCHOR_ROOT - 1) * t + 1
     * @param portionPT Portion of PT tokens in the pool (scaled by 1e18)
     * @return Calculated price (scaled by 1e18)
     */
    function calculatePrice(uint256 portionPT) internal view returns (int256) {
        // Get current time factor
        uint256 t = getCurrentTimeFactor();
        
        // Handle edge cases to avoid division by zero or log of zero/negative
        if (portionPT == 0) revert MathError(); // Portion PT should not be zero
        if (portionPT >= 1e18) revert MathError(); // Portion PT should be less than 1
        
        // Calculate ln(portion_PT / (1 - portion_PT))
        uint256 numerator = portionPT;
        uint256 denominator = 1e18 - portionPT;

        // Calculate the log term
        int256 logTerm = int256(MathLibrary.ln(numerator * 1e18)) - int256(MathLibrary.ln(denominator * 1e18));
        
        // The first component: (t / SCALAR_ROOT) * logTerm
        int256 firstComponent;
        if (logTerm >= 0) {
            firstComponent = int256(FullMath.mulDiv(uint256(logTerm), t, SCALAR_ROOT * 1e18));
        } else {
            firstComponent = -int256(FullMath.mulDiv(uint256(-logTerm), t, SCALAR_ROOT * 1e18));
        }
        
        // The second component: (ANCHOR_ROOT - 1) * t + 1
        int256 secondComponent = ((ANCHOR_ROOT - ANCHOR_BASE) * int256(t)) / 1e18 + ANCHOR_BASE;
        
        // Final price: firstComponent + secondComponent
        return firstComponent + secondComponent;
    }

    /**
     * @notice Helper function to calculate PT to SY price (inverse of SY to PT price)
     * @dev Price_PT = 1 / Price_SY when Price_SY > 0
     * @param priceSY The SY to PT price (scaled by 1e18)
     * @return pricePT The PT to SY price (scaled by 1e18)
     */
    function calculateInversePrice(int256 priceSY) internal pure returns (int256 pricePT) {
        // Handle edge cases
        if (priceSY <= 0) revert MathError(); // Price must be positive for inverse
        
        // Calculate inverse price: 1e18 / priceSY (maintaining 1e18 scaling)
        pricePT = int256(FullMath.mulDiv(1e18, 1e18, uint256(priceSY)));
        
        return pricePT;
    }

    // Externally visible helper function to get reserves for testing
    function getReserves(PoolKey calldata /* key */) external view returns (uint256 reserve0, uint256 reserve1) {
        return (reserveSY, reservePT);
    }
    
    /**
     * @notice Allow owner to update epoch parameters
     * @param _epochStart New epoch start time
     * @param _epochDuration New epoch duration
     */
    function setEpochParameters(uint256 _epochStart, uint256 _epochDuration) external onlyOwner {
        // Basic validation
        if (_epochDuration == 0) revert InvalidEpochParameters();
        
        epochStart = _epochStart;
        epochDuration = _epochDuration;
        
        emit ParametersUpdated(_epochStart, _epochDuration);
    }

    /**
     * @notice Implementation of BaseCustomCurve's _getUnspecifiedAmount
     * @dev Supports both SY to PT and PT to SY swaps in both exact input and exact output modes
     */
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        // Check swap direction and type
        if (params.zeroForOne) {
            // SY -> PT swap
            if (params.amountSpecified < 0) {
                // Exact input SY -> PT swap
                uint256 amountIn = uint256(-params.amountSpecified);
                return _getSYtoPTAmountOut(amountIn);
            } else {
                // Exact output SY -> PT swap
                uint256 amountOut = uint256(params.amountSpecified);
                return _getSYtoPTAmountIn(amountOut);
            }
        } else {
            // PT -> SY swap
            if (params.amountSpecified < 0) {
                // Exact input PT -> SY swap
                uint256 amountIn = uint256(-params.amountSpecified);
                return _getPTtoSYAmountOut(amountIn);
            } else {
                // Exact output PT -> SY swap
                uint256 amountOut = uint256(params.amountSpecified);
                return _getPTtoSYAmountIn(amountOut);
            }
        }
    }
    
    /**
     * @notice Calculate output amount of PT given an exact input amount of SY
     * @param amountIn Amount of SY tokens to swap
     * @return amountOut Amount of PT tokens to receive
     */
    function _getSYtoPTAmountOut(uint256 amountIn) internal view returns (uint256 amountOut) {
        // Check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidHookConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = FullMath.mulDiv(reserve1, 1e18, totalReserve);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore);
        
        // Calculate reserves after swap
        uint256 reserve0After = reserve0 + amountIn;
        
        // Estimate output using initial price
        uint256 estimatedDeltaPT;
        if (priceSYBefore >= 0) {
            estimatedDeltaPT = FullMath.mulDiv(amountIn, uint256(priceSYBefore), 1e18);
        } else {
            estimatedDeltaPT = 0;
        }
        
        uint256 reserve1After = reserve1 > estimatedDeltaPT ? reserve1 - estimatedDeltaPT : 0;
        uint256 totalReserveAfter = reserve0After + reserve1After;
        
        // Calculate portion_PT after swap
        uint256 portionPTAfter = FullMath.mulDiv(reserve1After, 1e18, totalReserveAfter);
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        // Calculate final output amount (PT)
        if (avgPrice >= 0) {
            amountOut = FullMath.mulDiv(amountIn, uint256(avgPrice), 1e18);
        } else {
            amountOut = 0;
        }
        
        // Ensure there's enough PT in the pool
        if (amountOut > reserve1) revert InsufficientPTReserves();
        
        return amountOut;
    }
    
    /**
     * @notice Calculate input amount of SY needed for exact output amount of PT
     * @param amountOut Desired amount of PT tokens to receive
     * @return amountIn Required amount of SY tokens to provide
     */
    function _getSYtoPTAmountIn(uint256 amountOut) internal view returns (uint256 amountIn) {
        // Check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Ensure there's enough PT in the pool
        if (amountOut > reservePT) revert InsufficientPTReserves();
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidHookConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = FullMath.mulDiv(reserve1, 1e18, totalReserve);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore);
        
        // Initial estimate for amountIn
        uint256 initialAmountIn;
        if (priceSYBefore > 0) {
            initialAmountIn = FullMath.mulDiv(amountOut, 1e18, uint256(priceSYBefore));
        } else {
            initialAmountIn = amountOut * 2;
        }
        
        // Iterative binary search to find the exact input amount
        uint256 low = 0;
        uint256 high = initialAmountIn * 2;
        uint256 maxIterations = 32;
        
        for (uint256 i = 0; i < maxIterations; i++) {
            uint256 mid = (low + high) / 2;
            
            if (mid == low || mid == high) {
                amountIn = high;
                break;
            }
            
            // Test this input amount
            uint256 reserve0Test = reserve0 + mid;
            uint256 totalReserveTest = reserve0Test + reserve1;
            uint256 portionPTTest = FullMath.mulDiv(reserve1, 1e18, totalReserveTest);
            int256 priceTest = calculatePrice(portionPTTest);
            
            uint256 outputTest;
            if (priceTest > 0) {
                outputTest = FullMath.mulDiv(mid, uint256(priceTest), 1e18);
            } else {
                outputTest = 0;
            }
            
            if (outputTest < amountOut) {
                low = mid;
            } else {
                high = mid;
                if (outputTest >= amountOut) {
                    amountIn = mid;
                }
            }
        }
        
        // Final check
        if (amountIn == 0) {
            if (priceSYBefore > 0) {
                amountIn = FullMath.mulDiv(amountOut, 12e17, uint256(priceSYBefore));
            } else {
                amountIn = amountOut * 3;
            }
        }
        
        return amountIn;
    }
    
    /**
     * @notice Calculate output amount of SY given exact input amount of PT
     * @param amountIn Amount of PT tokens to swap
     * @return amountOut Amount of SY tokens to receive
     */
    function _getPTtoSYAmountOut(uint256 amountIn) internal view returns (uint256 amountOut) {
        // Check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidHookConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = FullMath.mulDiv(reserve1, 1e18, totalReserve);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore);
        
        // Calculate Price_PT_Before (inverse of Price_SY_Before)
        int256 pricePTBefore;
        if (priceSYBefore > 0) {
            pricePTBefore = calculateInversePrice(priceSYBefore);
        } else {
            revert MathError(); // Cannot calculate with non-positive price
        }
        
        // Calculate reserves after swap
        uint256 reserve1After = reserve1 + amountIn;
        
        // Estimate output using initial price
        uint256 estimatedDeltaSY;
        if (pricePTBefore >= 0) {
            estimatedDeltaSY = FullMath.mulDiv(amountIn, uint256(pricePTBefore), 1e18);
        } else {
            estimatedDeltaSY = 0;
        }
        
        uint256 reserve0After = reserve0 > estimatedDeltaSY ? reserve0 - estimatedDeltaSY : 0;
        uint256 totalReserveAfter = reserve0After + reserve1After;
        
        // Calculate portion_PT after swap
        uint256 portionPTAfter = FullMath.mulDiv(reserve1After, 1e18, totalReserveAfter);
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter);
        
        // Calculate Price_PT_After
        int256 pricePTAfter;
        if (priceSYAfter > 0) {
            pricePTAfter = calculateInversePrice(priceSYAfter);
        } else {
            // Fallback to pre-swap price
            pricePTAfter = pricePTBefore;
        }
        
        // Calculate average price
        int256 avgPrice = (pricePTBefore + pricePTAfter) / 2;
        
        // Calculate final output amount (SY)
        if (avgPrice >= 0) {
            amountOut = FullMath.mulDiv(amountIn, uint256(avgPrice), 1e18);
        } else {
            amountOut = 0;
        }
        
        // Ensure there's enough SY in the pool
        if (amountOut > reserve0) revert InsufficientSYReserves();
        
        return amountOut;
    }
    
    /**
     * @notice Calculate input amount of PT needed for exact output amount of SY
     * @param amountOut Desired amount of SY tokens to receive
     * @return amountIn Required amount of PT tokens to provide
     */
    function _getPTtoSYAmountIn(uint256 amountOut) internal view returns (uint256 amountIn) {
        // Check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Ensure there's enough SY in the pool
        if (amountOut > reserveSY) revert InsufficientSYReserves();
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidHookConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = FullMath.mulDiv(reserve1, 1e18, totalReserve);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore);
        
        // Calculate Price_PT_Before (inverse of Price_SY_Before)
        int256 pricePTBefore;
        if (priceSYBefore > 0) {
            pricePTBefore = calculateInversePrice(priceSYBefore);
        } else {
            revert MathError(); // Cannot calculate with non-positive price
        }
        
        // Calculate reserves after swap
        uint256 reserve0After = reserve0 - amountOut;
        
        // Initial estimate for amountIn
        uint256 initialAmountIn;
        if (pricePTBefore > 0) {
            initialAmountIn = FullMath.mulDiv(amountOut, 1e18, uint256(pricePTBefore));
        } else {
            initialAmountIn = amountOut * 2;
        }
        
        // Iterative binary search to find the exact input amount
        uint256 low = 0;
        uint256 high = initialAmountIn * 2;
        uint256 maxIterations = 32;
        
        for (uint256 i = 0; i < maxIterations; i++) {
            uint256 mid = (low + high) / 2;
            
            if (mid == low || mid == high) {
                amountIn = high;
                break;
            }
            
            // Test this input amount
            uint256 reserve1Test = reserve1 + mid;
            uint256 totalReserveTest = reserve0 + reserve1Test;
            uint256 portionPTTest = FullMath.mulDiv(reserve1Test, 1e18, totalReserveTest);
            int256 priceSYTest = calculatePrice(portionPTTest);
            
            int256 pricePTTest;
            if (priceSYTest > 0) {
                pricePTTest = calculateInversePrice(priceSYTest);
            } else {
                pricePTTest = 0;
            }
            
            uint256 outputTest;
            if (pricePTTest > 0) {
                outputTest = FullMath.mulDiv(mid, uint256(pricePTTest), 1e18);
            } else {
                outputTest = 0;
            }
            
            if (outputTest < amountOut) {
                low = mid;
            } else {
                high = mid;
                if (outputTest >= amountOut) {
                    amountIn = mid;
                }
            }
        }
        
        // Final check
        if (amountIn == 0) {
            if (pricePTBefore > 0) {
                amountIn = FullMath.mulDiv(amountOut, 12e17, uint256(pricePTBefore));
            } else {
                amountIn = amountOut * 3;
            }
        }
        
        return amountIn;
    }
    
    /**
     * @notice Calculate output amount (in the form of liquidity/shares) for given token amounts
     * @dev Updated to use Uniswap V2 style formula
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        virtual
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        // Use desired amounts as actual amounts
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        
        // Uniswap V2 style liquidity calculation
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            // First liquidity provision
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
        } else {
            // Subsequent liquidity provisions - use mulDiv for safety
            uint256 liquidity0 = FullMath.mulDiv(amount0, _totalSupply, reserveSY);
            uint256 liquidity1 = FullMath.mulDiv(amount1, _totalSupply, reservePT);
            liquidity = Math.min(liquidity0, liquidity1);
        }
        
        if (liquidity <= 0) revert InsufficientLiquidity();
        
        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Calculate token amounts to return for given liquidity amount
     * @dev Simple pro-rata calculation
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        liquidity = params.liquidity;
        uint256 _totalSupply = totalSupply();
        
        // Calculate proportional share of reserves using mulDiv for safety
        amount0 = FullMath.mulDiv(reserveSY, liquidity, _totalSupply);
        amount1 = FullMath.mulDiv(reservePT, liquidity, _totalSupply);
        
        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Override the _beforeSwap hook to handle swap calculations and update reserves
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        // Now supporting both SY to PT swaps (zeroForOne = true) and PT to SY swaps (zeroForOne = false)
        
        if (params.zeroForOne) {
            // SY to PT swap
            if (params.amountSpecified < 0) {
                // Exact input swap (SY -> PT)
                uint256 specifiedAmount = uint256(-params.amountSpecified);
                uint256 unspecifiedAmount = _getSYtoPTAmountOut(specifiedAmount);
                
                // Call parent implementation to handle token settlement
                (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
                
                // Update our reserves after parent implementation
                reserveSY += specifiedAmount;
                reservePT -= unspecifiedAmount;
                
                emit ReservesUpdated(reserveSY, reservePT);
                return (selector, delta, fee);
            } else {
                // Exact output swap (SY -> PT)
                uint256 specifiedAmount = uint256(params.amountSpecified);
                uint256 unspecifiedAmount = _getSYtoPTAmountIn(specifiedAmount);
                
                // Call parent implementation to handle token settlement
                (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
                
                // Update our reserves after parent implementation
                reserveSY += unspecifiedAmount;
                reservePT -= specifiedAmount;
                
                emit ReservesUpdated(reserveSY, reservePT);
                return (selector, delta, fee);
            }
        } else {
            // PT to SY swap
            if (params.amountSpecified < 0) {
                // Exact input swap (PT -> SY)
                uint256 specifiedAmount = uint256(-params.amountSpecified);
                uint256 unspecifiedAmount = _getPTtoSYAmountOut(specifiedAmount);
                
                // Call parent implementation to handle token settlement
                (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
                
                // Update our reserves after parent implementation
                reservePT += specifiedAmount;
                reserveSY -= unspecifiedAmount;
                
                emit ReservesUpdated(reserveSY, reservePT);
                return (selector, delta, fee);
            } else {
                // Exact output swap (PT -> SY)
                uint256 specifiedAmount = uint256(params.amountSpecified);
                uint256 unspecifiedAmount = _getPTtoSYAmountIn(specifiedAmount);
                
                // Call parent implementation to handle token settlement
                (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
                
                // Update our reserves after parent implementation
                reservePT += unspecifiedAmount;
                reserveSY -= specifiedAmount;
                
                emit ReservesUpdated(reserveSY, reservePT);
                return (selector, delta, fee);
            }
        }
    }
    
    /**
     * @notice Mint liquidity shares using ERC20 functionality
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 shares) 
        internal 
        virtual
        override
    {
        // First liquidity provision requires minting MINIMUM_LIQUIDITY to the contract itself
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            super._mint(address(this), MINIMUM_LIQUIDITY);
            // Reduce shares by MINIMUM_LIQUIDITY that was locked in the contract
            shares -= MINIMUM_LIQUIDITY;
        }
        
        // Directly update reserves here since _afterAddLiquidity might not be called
        // delta amounts are negative when tokens are added to the pool
        if (delta.amount0() < 0) {
            // Converting -delta.amount0() to positive uint256
            reserveSY += uint256(int256(-delta.amount0()));
        }
        
        if (delta.amount1() < 0) {
            // Converting -delta.amount1() to positive uint256
            reservePT += uint256(int256(-delta.amount1()));
        }
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        _mint(params.to, shares);
    }
    
    /**
     * @notice Burn liquidity shares using ERC20 functionality
     */
    function _burn(RemoveLiquidityParams memory /* params */, BalanceDelta delta, uint256 shares) 
        internal 
        virtual
        override
    {
        // Directly update reserves here since _afterRemoveLiquidity might not be called
        // delta amounts are positive when tokens are removed from the pool
        if (delta.amount0() > 0) {
            // delta.amount0() is already positive
            reserveSY -= uint256(int256(delta.amount0()));
        }
        
        if (delta.amount1() > 0) {
            // delta.amount1() is already positive
            reservePT -= uint256(int256(delta.amount1()));
        }
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        _burn(msg.sender, shares);
    }
    
    /**
     * @notice Get PT quote for a specific SY amount (SY to PT exactInput)
     * @param key The pool key
     * @param sYAmount Amount of SY tokens to swap
     * @return ptAmount Estimated PT tokens to receive
     */
    function getQuote(PoolKey calldata key, uint256 sYAmount) external view returns (uint256 ptAmount) {
        return _getSYtoPTAmountOut(sYAmount);
    }
    
    /**
     * @notice Get SY amount required for a specific PT amount (SY to PT exactOutput)
     * @param key The pool key
     * @param ptAmount Desired amount of PT tokens to receive
     * @return syAmount Required SY tokens to provide
     */
    function getRequiredInputForOutput(PoolKey calldata key, uint256 ptAmount) external view returns (uint256 syAmount) {
        return _getSYtoPTAmountIn(ptAmount);
    }
    
    /**
     * @notice Get SY quote for a specific PT amount (PT to SY exactInput)
     * @param ptAmount Amount of PT tokens to swap
     * @return syAmount Estimated SY tokens to receive
     */
    function getQuotePTtoSY(uint256 ptAmount) external view returns (uint256 syAmount) {
        return _getPTtoSYAmountOut(ptAmount);
    }
    
    /**
     * @notice Get PT amount required for a specific SY amount (PT to SY exactOutput) 
     * @param syAmount Desired amount of SY tokens to receive
     * @return ptAmount Required PT tokens to provide
     */
    function getRequiredPTforSY(uint256 syAmount) external view returns (uint256 ptAmount) {
        return _getPTtoSYAmountIn(syAmount);
    }
}
