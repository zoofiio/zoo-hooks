// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {BaseCustomCurve} from "../lib/uniswap-hooks/src/base/BaseCustomCurve.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MathLibrary} from "./libraries/MathLibrary.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol"; // Add this import

/**
 * @title YieldSwapHook
 * @notice A custom AMM Hook for yield products based on Uniswap V4
 * @dev Provides custom pricing logic for SY and PT tokens
 */
contract YieldSwapHook is BaseCustomCurve, ERC20 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager; // Add this line
    
    // Parameters for the pricing formula (for single pool)
    uint256 public rateScalar;   // Denominator parameter in the pricing formula
    int256 public rateAnchor;    // Constant offset in the pricing formula
    
    // Default parameters (can be overridden by the owner)
    uint256 public constant DEFAULT_RATE_SCALAR = 100; // Default rate scalar
    int256 public constant DEFAULT_RATE_ANCHOR = 1.1e18; // Default rate anchor (1.1 with 18 decimals)
    
    // Owner address to control parameter settings
    address public owner;
    
    // Error declarations
    error OnlySYToPTSwapsSupported();
    error InvalidPoolConfiguration();
    error MathError();
    error InsufficientPTReserves();
    error OnlyOwner();
    
    event ParametersUpdated(uint256 rateScalar, int256 rateAnchor);
    
    constructor(IPoolManager _poolManager) 
        BaseCustomCurve(_poolManager) 
        ERC20("YieldSwap Liquidity", "YSL") 
    {
        owner = msg.sender;
        rateScalar = DEFAULT_RATE_SCALAR;
        rateAnchor = DEFAULT_RATE_ANCHOR;
    }
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }
    
    // Helper function to get reserves from a pool
    function getReservesForPool(PoolKey memory key) internal view returns (uint256 reserve0, uint256 reserve1) {
        // StateLibrary's getLiquidity returns a single liquidity value, not a tuple with 4 components
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        
        // In a yield swap contract, we're dealing with SY (token0) and PT (token1)
        // For simplicity, we'll split the liquidity equally, but in a real implementation
        // you would need to calculate these based on your specific pricing model
        reserve0 = liquidity / 2;
        reserve1 = liquidity / 2;
        return (reserve0, reserve1);
    }
    
    // New externally visible helper function to get reserves for testing
    function getReserves(PoolKey calldata key) external view returns (uint256 reserve0, uint256 reserve1) {
        return getReservesForPool(key);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        owner = newOwner;
    }
    
    // Allow owner to set parameters for the pool
    function setPoolParameters(PoolKey calldata, uint256 _rateScalar, int256 _rateAnchor) external onlyOwner {
        // Instead of checking initialized, check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        if (_rateScalar == 0) revert InvalidPoolConfiguration();
        
        rateScalar = _rateScalar;
        rateAnchor = _rateAnchor;
        
        emit ParametersUpdated(_rateScalar, _rateAnchor);
    }
    
    /**
     * @notice Helper function to calculate price using the formula
     * @dev Price_SY = (1 / RateScalar) * ln (Portion_PT / (1 - Portion_PT)) + RateAnchor
     * @param portionPT Portion of PT tokens in the pool (scaled by 1e18)
     * @param scalarParam Rate scalar parameter
     * @param anchorParam Rate anchor parameter
     * @return Calculated price (scaled by 1e18)
     */
    function calculatePrice(uint256 portionPT, uint256 scalarParam, int256 anchorParam) internal pure returns (int256) {
        // Handle edge cases to avoid division by zero or log of zero/negative
        if (portionPT == 0) return anchorParam;
        if (portionPT >= 1e18) revert MathError(); // Portion PT should be less than 1
        
        // Calculate ln(portion_PT / (1 - portion_PT))
        // Using 18 decimal precision
        uint256 numerator = portionPT;
        uint256 denominator = 1e18 - portionPT;

        // Use the MathLibrary library for ln calculations
        int256 logTerm = int256(MathLibrary.ln(numerator * 1e18)) - int256(MathLibrary.ln(denominator * 1e18));
        console.log("YieldSwapHook: calculatePrice, ln(numerator): ", numerator * 1e18, MathLibrary.ln(numerator * 1e18));
        console.log("YieldSwapHook: calculatePrice, ln(denominator): ", denominator * 1e18, MathLibrary.ln(denominator * 1e18));

        console.log("YieldSwapHook: calculatePrice, logTerm: ", logTerm);
        
        // Calculate (1 / rateScalar) * ln(...)
        int256 scaledLog = logTerm / int256(scalarParam);
        
        // Final formula: scaled_log + rateAnchor
        return scaledLog + anchorParam;
    }

    /**
     * @notice Implementation of BaseCustomCurve's _getUnspecifiedAmount
     */
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        // Determine if the swap is exact input or exact output
        bool exactInput = params.amountSpecified < 0;
        
        // For SY to PT swaps (zeroForOne = true)
        if (params.zeroForOne) {
            // If exact input, calculate how much PT user gets
            if (exactInput) {
                return _getAmountOutFromExactInput(uint256(-params.amountSpecified), poolKey.currency0, poolKey.currency1, params.zeroForOne);
            } 
            // If exact output, calculate how much SY user pays
            else {
                return _getAmountInForExactOutput(uint256(params.amountSpecified), poolKey.currency0, poolKey.currency1, params.zeroForOne);
            }
        }
        
        // For PT to SY swaps (zeroForOne = false) - not supported in our model
        revert OnlySYToPTSwapsSupported();
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
        
        // Get reserves
        (uint256 reserve0, uint256 reserve1) = getReservesForPool(poolKey);
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidPoolConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = (reserve1 * 1e18) / totalReserve;
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore, rateScalar, rateAnchor);
        
        // Calculate reserves after swap
        uint256 reserve0After = reserve0 + amountIn;
        
        // Estimate output using initial price
        int256 estimatedDeltaPT = (int256(amountIn) * priceSYBefore) / 1e18;
        uint256 reserve1After = reserve1 > uint256(estimatedDeltaPT) 
            ? reserve1 - uint256(estimatedDeltaPT) 
            : 0;
            
        uint256 totalReserveAfter = reserve0After + reserve1After;
        
        // Calculate portion_PT after swap
        uint256 portionPTAfter = (reserve1After * 1e18) / totalReserveAfter;
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter, rateScalar, rateAnchor);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        // Calculate final output amount (PT)
        amountOut = uint256((int256(amountIn) * avgPrice) / 1e18);
        
        // Ensure there's enough PT in the pool
        if (amountOut > reserve1) revert InsufficientPTReserves();
        
        return amountOut;
    }
    
    /**
     * @notice Calculate input amount (SY) needed for exact output amount (PT)
     */
    function _getAmountInForExactOutput(
        uint256 amountOut,
        Currency /* input */,
        Currency /* output */,
        bool zeroForOne
    ) internal view virtual returns (uint256 amountIn) {
        // In our model, we only support SY to PT swaps (zeroForOne = true)
        if (!zeroForOne) revert OnlySYToPTSwapsSupported();
        
        // Instead of checking initialized, check if poolKey is set
        if (Currency.unwrap(poolKey.currency0) == address(0)) revert PoolNotInitialized();
        
        // Get reserves
        (uint256 reserve0, uint256 reserve1) = getReservesForPool(poolKey);
        
        // Ensure there's enough PT in the pool
        if (amountOut > reserve1) revert InsufficientPTReserves();
        
        uint256 totalReserve = reserve0 + reserve1;
        if (totalReserve == 0) revert InvalidPoolConfiguration();
        
        // Calculate portion_PT before swap
        uint256 portionPTBefore = (reserve1 * 1e18) / totalReserve;
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore, rateScalar, rateAnchor);
        
        // Calculate reserves after swap
        uint256 reserve1After = reserve1 - amountOut;
        
        // Estimate input using initial price (inverse of price)
        // amountIn ≈ amountOut / price
        uint256 estimatedAmountIn = uint256((int256(amountOut) * 1e18) / priceSYBefore);
        uint256 reserve0After = reserve0 + estimatedAmountIn;
        
        uint256 totalReserveAfter = reserve0After + reserve1After;
        
        // Calculate portion_PT after swap
        uint256 portionPTAfter = (reserve1After * 1e18) / totalReserveAfter;
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter, rateScalar, rateAnchor);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        // Re-calculate final input amount (SY) using average price
        amountIn = uint256((int256(amountOut) * 1e18) / avgPrice);
        
        return amountIn;
    }
    
    /**
     * @notice Calculate output amount (in the form of liquidity/shares) for given token amounts
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
        
        // Calculate liquidity based on 50/50 weighting
        liquidity = (amount0 + amount1) / 2;
        
        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Calculate token amounts to return for given liquidity amount
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        // Simple 50/50 split for removed liquidity
        amount0 = params.liquidity / 2;
        amount1 = params.liquidity / 2;
        liquidity = params.liquidity;
        
        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Mint liquidity shares using ERC20 functionality
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta /* delta */, uint256 shares) 
        internal 
        virtual
        override
    {
        _mint(params.to, shares);
    }
    
    /**
     * @notice Burn liquidity shares using ERC20 functionality
     */
    function _burn(RemoveLiquidityParams memory /* params */, BalanceDelta /* delta */, uint256 shares) 
        internal 
        virtual
        override
    {
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
