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
    error OnlySYToPTSwapsSupported();
    error InvalidHookConfiguration();
    error MathError();
    error InsufficientPTReserves();
    error ExactInputOnly();
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
        int256 logTerm = this.calculateLogTerm(numerator, denominator);
        console.log("YieldSwapHook: calculatePrice, ln(numerator): ", numerator * 1e18, MathLibrary.ln(numerator * 1e18));
        console.log("YieldSwapHook: calculatePrice, ln(denominator): ", denominator * 1e18, MathLibrary.ln(denominator * 1e18));
        console.log("YieldSwapHook: calculatePrice, logTerm: ", logTerm);
        
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
     * @notice External function to safely calculate log term
     * @dev Made external to use try/catch for error handling
     */
    function calculateLogTerm(uint256 numerator, uint256 denominator) external pure returns (int256) {
        int256 logTerm = int256(MathLibrary.ln(numerator * 1e18)) - int256(MathLibrary.ln(denominator * 1e18));
        return logTerm;
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
     * @dev Only supports exact input swaps (amountSpecified < 0)ot - 1) * t + 1
     */
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        // Check for exact input vs exact output first
        if (params.amountSpecified >= 0) {
            revert ExactInputOnly();
        }
        
        // Then check swap direction
        if (params.zeroForOne) {
            // Get absolute value of input amount
            uint256 amountIn = uint256(-params.amountSpecified);
            return _getAmountOutFromExactInput(amountIn, poolKey.currency0, poolKey.currency1, params.zeroForOne);
        } else {
            // For PT to SY swaps (zeroForOne = false) - not supported in our model
            revert OnlySYToPTSwapsSupported();
        }
    }
    
    /**
     * @notice Calculate output amount (PT) given exact input amount (SY)
     */
    function _getAmountOutFromExactInput(
        uint256 amountIn,
        Currency /* input */,
        Currency /* output */,
        bool zeroForOne
    ) internal view virtual returns (uint256 amountOut) {
        // In our model, we only support SY to PT swaps (zeroForOne = true)
        if (!zeroForOne) revert OnlySYToPTSwapsSupported();
        
        // Instead of checking initialized, check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidHookConfiguration();
        
        // Calculate portion_PT before swap using mulDiv for safety
        uint256 portionPTBefore = FullMath.mulDiv(reserve1, 1e18, totalReserve);
        
        // Calculate Price_SY_Before using current time-based parameters
        int256 priceSYBefore = calculatePrice(portionPTBefore);
        
        // Calculate reserves after swap
        uint256 reserve0After = reserve0 + amountIn;
        
        // Estimate output using initial price - handle signed arithmetic carefully
        uint256 estimatedDeltaPT;
        if (priceSYBefore >= 0) {
            estimatedDeltaPT = FullMath.mulDiv(amountIn, uint256(priceSYBefore), 1e18);
        } else {
            // If price is negative (unusual but possible in some models), we'd get zero PT
            estimatedDeltaPT = 0;
        }
        
        uint256 reserve1After = reserve1 > estimatedDeltaPT ? reserve1 - estimatedDeltaPT : 0;
        uint256 totalReserveAfter = reserve0After + reserve1After;
        
        // Calculate portion_PT after swap using mulDiv
        uint256 portionPTAfter = FullMath.mulDiv(reserve1After, 1e18, totalReserveAfter);
        
        // Calculate Price_SY_After using current time-based parameters
        int256 priceSYAfter = calculatePrice(portionPTAfter);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        // Calculate final output amount (PT) - handle signed arithmetic carefully
        if (avgPrice >= 0) {
            amountOut = FullMath.mulDiv(amountIn, uint256(avgPrice), 1e18);
        } else {
            // If average price is negative, return zero
            amountOut = 0;
        }
        
        // Ensure there's enough PT in the pool
        if (amountOut > reserve1) revert InsufficientPTReserves();
        
        return amountOut;
    }
    
    /**
     * @notice Calculate input amount (SY) needed for exact output amount (PT)
     * @dev Not used due to exactInput only restriction
     */
    function _getAmountInForExactOutput(
        uint256 /* amountOut */,
        Currency /* input */,
        Currency /* output */,
        bool /* zeroForOne */
    ) internal view virtual returns (uint256 /* amountIn */) {
        // This function won't be called since we restrict to exactInput only
        revert ExactInputOnly();
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
        // Only handle SY to PT swaps (zeroForOne = true)
        if (!params.zeroForOne) {
            revert OnlySYToPTSwapsSupported();
        }
        
        // Only support exactInput swaps - check this before calculating anything
        // Skip super._beforeSwap entirely for exactOutput swaps
        if (params.amountSpecified >= 0) {
            revert ExactInputOnly();
        }
        
        // Get absolute value of input amount (SY)
        uint256 specifiedAmount = uint256(-params.amountSpecified);
        
        // Calculate output amount (PT) before calling super._beforeSwap
        uint256 unspecifiedAmount = _getAmountOutFromExactInput(
            specifiedAmount,
            poolKey.currency0,
            poolKey.currency1,
            params.zeroForOne
        );
        
        // Call parent implementation to handle token settlement
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
        
        // Update our reserves after parent implementation
        reserveSY += specifiedAmount;
        reservePT -= unspecifiedAmount;
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        return (selector, delta, fee);
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
     * @notice Get PT quote for a specific SY amount
     * @param key The pool key
     * @param sYAmount Amount of SY tokens to swap
     * @return ptAmount Estimated PT tokens to receive
     */
    function getQuote(PoolKey calldata key, uint256 sYAmount) external view returns (uint256 ptAmount) {
        return _getAmountOutFromExactInput(sYAmount, key.currency0, key.currency1, true);
    }
    
}
