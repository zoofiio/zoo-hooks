// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/**
 * @title YieldSwapHook
 * @notice A custom AMM Hook for yield products based on Uniswap V4
 * @dev Provides custom pricing logic for SY and PT tokens
 */
contract YieldSwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency; // Add this to use take() and settle() methods
    using SafeCast for uint256;
    using SafeCast for int256;
    using BalanceDeltaLibrary for BalanceDelta;
    
    // Parameters for the pricing formula
    struct PoolParameters {
        uint256 rateScalar;   // Denominator parameter in the pricing formula
        int256 rateAnchor;    // Constant offset in the pricing formula
        uint256 reserveSY;    // Current SY token reserves
        uint256 reservePT;    // Current PT token reserves
        bool initialized;     // Whether the pool is initialized
    }
    
    // Default parameters (can be overridden by the owner)
    uint256 public constant DEFAULT_RATE_SCALAR = 100; // Default rate scalar
    int256 public constant DEFAULT_RATE_ANCHOR = 1.1e18; // Default rate anchor (1.1 with 18 decimals)
    
    // Mapping from pool ID to its parameters
    mapping(PoolId => PoolParameters) public poolParams;
    
    // Owner address to control parameter settings
    address public owner;
    
    // Error declarations
    error PoolNotInitialized();
    error OnlySYToPTSwapsSupported();
    error InvalidPoolConfiguration();
    error MathError();
    error InsufficientPTReserves();
    error OnlyOwner();
    
    event ParametersUpdated(PoolId indexed poolId, uint256 rateScalar, int256 rateAnchor);
    
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        owner = newOwner;
    }
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,  // Changed to true to completely override swap logic
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    // Allow owner to set parameters for a pool
    function setPoolParameters(PoolKey calldata key, uint256 rateScalar, int256 rateAnchor) external onlyOwner {
        PoolId poolId = key.toId();
        if (!poolParams[poolId].initialized) revert PoolNotInitialized();
        
        if (rateScalar == 0) revert InvalidPoolConfiguration();
        
        poolParams[poolId].rateScalar = rateScalar;
        poolParams[poolId].rateAnchor = rateAnchor;
        
        emit ParametersUpdated(poolId, rateScalar, rateAnchor);
    }
    
    /**
     * @notice Implementation of natural log function for fixed point numbers
     * @dev Implements ln(x) with x scaled by 1e18
     * @param x The input value (must be > 0)
     * @return The natural logarithm of x, scaled by 1e18
     */
    function ln(uint256 x) internal pure returns (uint256) {
        if (x == 0) revert MathError();
        
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
    
    /**
     * @notice Helper function to calculate price using the formula
     * @dev Price_SY = (1 / RateScalar) * ln (Portion_PT / (1 - Portion_PT)) + RateAnchor
     * @param portionPT Portion of PT tokens in the pool (scaled by 1e18)
     * @param rateScalar Rate scalar parameter
     * @param rateAnchor Rate anchor parameter
     * @return Calculated price (scaled by 1e18)
     */
    function calculatePrice(uint256 portionPT, uint256 rateScalar, int256 rateAnchor) internal pure returns (int256) {
        // Handle edge cases to avoid division by zero or log of zero/negative
        if (portionPT == 0) return rateAnchor;
        if (portionPT >= 1e18) revert MathError(); // Portion PT should be less than 1
        
        // Calculate ln(portion_PT / (1 - portion_PT))
        // Using 18 decimal precision
        uint256 numerator = portionPT;
        uint256 denominator = 1e18 - portionPT;
        
        // Calculate ratio and maintain appropriate scaling
        // uint256 ratio = (numerator * 1e18) / denominator;
        
        // Use our custom ln function to calculate ln(ratio)
        // int256 logTerm = int256(ln(ratio));
        // logTerm = logTerm - int256(ln(1e18)); // Adjust for scaling

        int256 logTerm = int256(ln(numerator * 1e18)) - int256(ln(denominator * 1e18));
        console.log("YieldSwapHook: calculatePrice, ln(numerator): ", numerator * 1e18, ln(numerator * 1e18));
        console.log("YieldSwapHook: calculatePrice, ln(denominator): ", denominator * 1e18, ln(denominator * 1e18));

        // console.log("YieldSwapHook: calculatePrice, ratio: ", ratio);
        console.log("YieldSwapHook: calculatePrice, logTerm: ", logTerm);
        
        // Calculate (1 / rateScalar) * ln(...)
        int256 scaledLog = logTerm / int256(rateScalar);
        
        // Final formula: scaled_log + rateAnchor
        return scaledLog + rateAnchor;
    }
    
    /**
     * @notice Initialize pool parameters
     * @dev Called when a new pool is initialized
     * @param key The pool key
     */
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        // Use default values but ensure we have some minimal reserves to prevent math errors
        uint256 rateScalar = DEFAULT_RATE_SCALAR;
        int256 rateAnchor = DEFAULT_RATE_ANCHOR;
        
        // DON'T set initial reserves here - these reserves are set via liquidity operations
        // Setting them here would conflict with actual liquidity added through Uniswap
        
        // Store parameters
        poolParams[key.toId()] = PoolParameters({
            rateScalar: rateScalar,
            rateAnchor: rateAnchor,
            reserveSY: 0,
            reservePT: 0,
            initialized: true
        });
        
        return BaseHook.beforeInitialize.selector;
    }
    
    // Monitor liquidity additions - changed to override returns from view to pure
    function _beforeAddLiquidity(
        address,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        // Removed the check for initialized pool since it will cause problems
        // during initial pool setup - let the main Uniswap protocol handle this check
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    // Update reserves after liquidity is added
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Update our reserve tracking
        PoolParameters storage poolParam = poolParams[key.toId()];
        
        // Update reserves based on delta - using BalanceDeltaLibrary
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        console.log("YieldSwapHook: _afterAddLiquidity, amount0: ", amount0);
        console.log("YieldSwapHook: _afterAddLiquidity, amount1: ", amount1);
        console.log("YieldSwapHook: _afterAddLiquidity, reserveSY before: ", poolParam.reserveSY);
        console.log("YieldSwapHook: _afterAddLiquidity, reservePT before: ", poolParam.reservePT);
        
        // Fix: In Uniswap V4, negative amounts in addLiquidity mean tokens are added to LP positions
        // So for our tracking, we need to ADD the absolute value to our reserves
        if (amount0 < 0) poolParam.reserveSY += uint256(uint128(-amount0));
        if (amount0 > 0) poolParam.reserveSY -= uint256(uint128(amount0));
        
        if (amount1 < 0) poolParam.reservePT += uint256(uint128(-amount1));
        if (amount1 > 0) poolParam.reservePT -= uint256(uint128(amount1));

        console.log("YieldSwapHook: _afterAddLiquidity, reserveSY after: ", poolParam.reserveSY);
        console.log("YieldSwapHook: _afterAddLiquidity, reservePT after: ", poolParam.reservePT);
        
        return (BaseHook.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }
    
    // Monitor liquidity removals - changed to override returns from view to pure
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        // Removed the check for initialized pool since it will cause problems
        // during initial pool setup - let the main Uniswap protocol handle this check
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }
    
    // Update reserves after liquidity is removed
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Update our reserve tracking
        PoolParameters storage poolParam = poolParams[key.toId()];
        
        // Update reserves based on delta - using BalanceDeltaLibrary
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        
        console.log("YieldSwapHook: _afterRemoveLiquidity, amount0: ", amount0);
        console.log("YieldSwapHook: _afterRemoveLiquidity, amount1: ", amount1);
        console.log("YieldSwapHook: _afterRemoveLiquidity, reserveSY before: ", poolParam.reserveSY);
        console.log("YieldSwapHook: _afterRemoveLiquidity, reservePT before: ", poolParam.reservePT);
        
        // Fix: In Uniswap V4, positive amounts in removeLiquidity mean tokens are removed from LP positions
        // So for our tracking, we need to SUBTRACT the value from our reserves
        if (amount0 > 0) poolParam.reserveSY -= uint256(uint128(amount0));
        if (amount0 < 0) poolParam.reserveSY += uint256(uint128(-amount0));
        
        if (amount1 > 0) poolParam.reservePT -= uint256(uint128(amount1));
        if (amount1 < 0) poolParam.reservePT += uint256(uint128(-amount1));
        
        console.log("YieldSwapHook: _afterRemoveLiquidity, reserveSY after: ", poolParam.reserveSY);
        console.log("YieldSwapHook: _afterRemoveLiquidity, reservePT after: ", poolParam.reservePT);
        
        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }
    
    /**
     * @notice Implements custom yield swap logic through the beforeSwap hook
     * @dev Based on the same pricing logic but using the beforeSwap hook interface
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Fetch the pool parameters
        PoolParameters storage poolParam = poolParams[key.toId()];
        if (!poolParam.initialized) revert PoolNotInitialized();
        
        // In our model:
        // - zeroForOne means SY -> PT (we only support this direction)
        // - oneForZero means PT -> SY (not supported)
        if (!params.zeroForOne) revert OnlySYToPTSwapsSupported();
        
        // Get reserves
        uint256 reserveSY = poolParam.reserveSY;
        uint256 reservePT = poolParam.reservePT;
        
        // Calculate portion_PT before swap
        uint256 totalReserve = reserveSY + reservePT;
        if (totalReserve == 0) revert InvalidPoolConfiguration();
        
        uint256 portionPTBefore = (reservePT * 1e18) / totalReserve;
        console.log("YieldSwapHook: _beforeSwap, portionPTBefore: ", portionPTBefore);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore, poolParam.rateScalar, poolParam.rateAnchor);
        console.log("YieldSwapHook: _beforeSwap, priceSYBefore: ", priceSYBefore);
        
        // Calculate amount of SY being swapped
        uint256 deltaSY = uint256(-params.amountSpecified); // Assume amountSpecified is negative for exactInput
        
        // Virtual swap: Calculate new reserves after the swap
        uint256 reserveSYAfter = reserveSY + deltaSY;
        console.log("YieldSwapHook: _beforeSwap, reserveSYAfter: ", reserveSYAfter);
        
        // Temporarily estimate a virtual deltaPT for calculation
        // Using priceSYBefore as an initial estimate
        int256 estimatedDeltaPT = (int256(deltaSY) * priceSYBefore) / 1e18;
        console.log("YieldSwapHook: _beforeSwap, estimatedDeltaPT: ", estimatedDeltaPT);
        
        // Calculate reserves after virtual swap
        uint256 reservePTAfter = reservePT > uint256(estimatedDeltaPT) 
            ? reservePT - uint256(estimatedDeltaPT) 
            : 0;
            
        uint256 totalReserveAfter = reserveSYAfter + reservePTAfter;
        
        // Calculate portion_PT after virtual swap
        uint256 portionPTAfter = totalReserveAfter > 0 
            ? (reservePTAfter * 1e18) / totalReserveAfter 
            : 0;
        console.log("YieldSwapHook: _beforeSwap, portionPTAfter: ", portionPTAfter);
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter, poolParam.rateScalar, poolParam.rateAnchor);
        console.log("YieldSwapHook: _beforeSwap, priceSYAfter: ", priceSYAfter);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        // Calculate how much PT the user will receive based on average price
        int256 deltaPT = (int256(deltaSY) * avgPrice) / 1e18;

        console.log("YieldSwapHook: _beforeSwap, deltaSY: ", deltaSY);
        console.log("YieldSwapHook: _beforeSwap, deltaPT: ", deltaPT);
        console.log("YieldSwapHook: _beforeSwap, reserveSY before: ", poolParam.reserveSY);
        console.log("YieldSwapHook: _beforeSwap, reservePT before: ", poolParam.reservePT);
        
        // Ensure there's enough PT in the pool
        if (uint256(deltaPT) > poolParam.reservePT) revert InsufficientPTReserves();
        
        // Update our internal tracking of reserves
        poolParam.reserveSY += deltaSY;
        poolParam.reservePT -= uint256(deltaPT);

        uint256 ptOutput = uint256(deltaPT);
        
        // CRITICAL: Properly settle the currencies with the PoolManager
        // 1. Take the input currency (SY) from the pool
        key.currency0.take(poolManager, address(this), deltaSY, true);
        
        // 2. Settle the output currency (PT) to the pool
        key.currency1.settle(poolManager, sender, ptOutput, true);
        
        // BeforeSwapDelta delta = toBeforeSwapDelta(-int128(deltaSY.toInt256()), int128(deltaPT));
        BeforeSwapDelta delta = toBeforeSwapDelta(-int128(deltaSY.toInt256()), int128(deltaPT));
        return (this.beforeSwap.selector, delta, 0);
    }
    
    /**
     * @notice Get current pool reserves
     * @param key The pool key
     * @return reserveSY SY token reserves
     * @return reservePT PT token reserves
     */
    function getReserves(PoolKey calldata key) external view returns (uint256 reserveSY, uint256 reservePT) {
        PoolParameters storage poolParam = poolParams[key.toId()];
        if (!poolParam.initialized) revert PoolNotInitialized();
        
        return (poolParam.reserveSY, poolParam.reservePT);
    }
    
    /**
     * @notice Get PT quote for a specific SY amount
     * @param key The pool key
     * @param sYAmount Amount of SY tokens to swap
     * @return ptAmount Estimated PT tokens to receive
     */
    function getQuote(PoolKey calldata key, uint256 sYAmount) external view returns (uint256 ptAmount) {
        PoolParameters storage poolParam = poolParams[key.toId()];
        if (!poolParam.initialized) {
            // Return a default quote if pool is not initialized
            return (sYAmount * DEFAULT_RATE_SCALAR) / 100; // Simple default pricing
        }
        
        // Get reserves
        uint256 reserveSY = poolParam.reserveSY;
        uint256 reservePT = poolParam.reservePT;
        
        // Calculate current portion_PT
        uint256 totalReserve = reserveSY + reservePT;
        // Prevent division by zero
        if (totalReserve == 0) {
            // If reserves are zero, use a default price based on parameters
            return (sYAmount * uint256(int256(1e18) + poolParam.rateAnchor)) / 1e18;
        }
        
        uint256 portionPTBefore = (reservePT * 1e18) / totalReserve;
        console.log("YieldSwapHook: getQuote, portionPTBefore: ", portionPTBefore);
        
        // Calculate Price_SY_Before
        int256 priceSYBefore = calculatePrice(portionPTBefore, poolParam.rateScalar, poolParam.rateAnchor);
        console.log("YieldSwapHook: getQuote, priceSYBefore: ", priceSYBefore);
        
        // Calculate new reserves and portion_PT
        uint256 reserveSYAfter = reserveSY + sYAmount;
        console.log("YieldSwapHook: getQuote, reserveSYAfter: ", reserveSYAfter);
        
        // Temporarily assume a virtual swap using previous price as initial estimate
        int256 estimatedDeltaPT = (int256(sYAmount) * priceSYBefore) / 1e18;
        console.log("YieldSwapHook: getQuote, estimatedDeltaPT: ", estimatedDeltaPT);
        
        uint256 reservePTAfter = reservePT > uint256(estimatedDeltaPT) 
            ? reservePT - uint256(estimatedDeltaPT) 
            : 0;
            
        uint256 totalReserveAfter = reserveSYAfter + reservePTAfter;
        // Prevent division by zero
        if (totalReserveAfter == 0) return 0;
        
        uint256 portionPTAfter = (reservePTAfter * 1e18) / totalReserveAfter;
        console.log("YieldSwapHook: getQuote, portionPTAfter: ", portionPTAfter);
        
        // Calculate Price_SY_After
        int256 priceSYAfter = calculatePrice(portionPTAfter, poolParam.rateScalar, poolParam.rateAnchor);
        console.log("YieldSwapHook: getQuote, priceSYAfter: ", priceSYAfter);
        
        // Calculate average price
        int256 avgPrice = (priceSYBefore + priceSYAfter) / 2;
        
        console.log("YieldSwapHook: getQuote, deltaPT: ", uint256((int256(sYAmount) * avgPrice) / 1e18));
        // Calculate PT amount using average price
        return uint256((int256(sYAmount) * avgPrice) / 1e18);
    }
}
