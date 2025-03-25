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
import {MathLibrary} from "./libraries/MathLibrary.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ZooCustomCurve} from "src/base/ZooCustomCurve.sol";

/**
 * @title YieldSwapHook
 * @notice A custom AMM Hook for yield products based on Uniswap V4
 * @dev Provides custom pricing logic for SY and PT tokens
 */
contract YieldSwapHook is ZooCustomCurve, ERC20 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    
    // Parameters for the pricing formula (for single pool)
    uint256 public rateScalar;   // Denominator parameter in the pricing formula
    int256 public rateAnchor;    // Constant offset in the pricing formula
    
    // Default parameters (can be overridden by the owner)
    uint256 public constant DEFAULT_RATE_SCALAR = 100; // Default rate scalar
    int256 public constant DEFAULT_RATE_ANCHOR = 1.1e18; // Default rate anchor (1.1 with 18 decimals)
    
    // Owner address to control parameter settings
    address public owner;
    
    // Track reserves manually
    uint256 public reserveSY;    // Reserve of SY tokens (token0)
    uint256 public reservePT;    // Reserve of PT tokens (token1)
    
    // Minimum liquidity constant (Uniswap V2 style)
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Error declarations
    error OnlySYToPTSwapsSupported();
    error InvalidPoolConfiguration();
    error MathError();
    error InsufficientPTReserves();
    error OnlyOwner();
    error ExactInputOnly();      // New error for exact input only swaps
    error InsufficientLiquidity();
    
    event ParametersUpdated(uint256 rateScalar, int256 rateAnchor);
    event ReservesUpdated(uint256 reserveSY, uint256 reservePT);
    
    constructor(IPoolManager _poolManager) 
        ZooCustomCurve(_poolManager) 
        ERC20("YieldSwap Liquidity", "YSL") 
    {
        owner = msg.sender;
        rateScalar = DEFAULT_RATE_SCALAR;
        rateAnchor = DEFAULT_RATE_ANCHOR;
        // Reserves start at 0
        reserveSY = 0;
        reservePT = 0;
    }
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // Externally visible helper function to get reserves for testing
    function getReserves(PoolKey calldata /* key */) external view returns (uint256 reserve0, uint256 reserve1) {
        return (reserveSY, reservePT);
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
     * @dev Only supports exact input swaps (amountSpecified < 0)
     */
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        // CHANGE: Only support exactInput swaps
        if (params.amountSpecified >= 0) {
            revert ExactInputOnly();
        }
        
        // For SY to PT swaps (zeroForOne = true)
        if (params.zeroForOne) {
            // Get absolute value of input amount
            uint256 amountIn = uint256(-params.amountSpecified);
            return _getAmountOutFromExactInput(amountIn, poolKey.currency0, poolKey.currency1, params.zeroForOne);
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
        
        // Use our tracked reserves
        uint256 reserve0 = reserveSY;
        uint256 reserve1 = reservePT;
        
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
            // Subsequent liquidity provisions
            liquidity = Math.min(
                (amount0 * _totalSupply) / reserveSY, 
                (amount1 * _totalSupply) / reservePT
            );
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
        
        // Calculate proportional share of reserves
        amount0 = (reserveSY * liquidity) / _totalSupply;
        amount1 = (reservePT * liquidity) / _totalSupply;
        
        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Process after liquidity is added to update our tracked reserves
     */
    function _afterAddLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        BalanceDelta delta,
        BalanceDelta /* feeDelta */,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, BalanceDelta) {
        // Update reserves based on the delta
        // delta amounts are negative when tokens are added to the pool
        if (delta.amount0() < 0) {
            // Converting -delta.amount0() to positive uint256
            reserveSY += uint256(int256(-delta.amount0()));
        } else {
            // delta.amount0() is already positive
            reserveSY -= uint256(int256(delta.amount0()));
        }
        
        if (delta.amount1() < 0) {
            // Converting -delta.amount1() to positive uint256
            reservePT += uint256(int256(-delta.amount1()));
        } else {
            // delta.amount1() is already positive
            reservePT -= uint256(int256(delta.amount1()));
        }
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        // First liquidity provision - mint MINIMUM_LIQUIDITY to the contract itself instead of address(0)
        if (totalSupply() == MINIMUM_LIQUIDITY) {
            super._mint(address(this), MINIMUM_LIQUIDITY);
        }
        
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
    
    /**
     * @notice Process after liquidity is removed to update our tracked reserves
     */
    function _afterRemoveLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        BalanceDelta delta,
        BalanceDelta /* feeDelta */,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, BalanceDelta) {
        // Update reserves based on the delta
        // delta amounts are positive when tokens are removed from the pool
        if (delta.amount0() > 0) {
            // delta.amount0() is already positive
            reserveSY -= uint256(int256(delta.amount0()));
        } else {
            // Converting -delta.amount0() to positive uint256
            reserveSY += uint256(int256(-delta.amount0()));
        }
        
        if (delta.amount1() > 0) {
            // delta.amount1() is already positive
            reservePT -= uint256(int256(delta.amount1()));
        } else {
            // Converting -delta.amount1() to positive uint256
            reservePT += uint256(int256(-delta.amount1()));
        }
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
    
    /**
     * @notice Process after swap to update our tracked reserves
     */
    function _afterSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        // Update reserves based on the swap delta
        if (delta.amount0() > 0) {
            // delta.amount0() is already positive
            reserveSY -= uint256(int256(delta.amount0()));
        } else {
            // Converting -delta.amount0() to positive uint256
            reserveSY += uint256(int256(-delta.amount0()));
        }
        
        if (delta.amount1() > 0) {
            // delta.amount1() is already positive
            reservePT -= uint256(int256(delta.amount1()));
        } else {
            // Converting -delta.amount1() to positive uint256
            reservePT += uint256(int256(-delta.amount1()));
        }
        
        emit ReservesUpdated(reserveSY, reservePT);
        
        return (this.afterSwap.selector, 0);
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
    
    /**
     * @notice Set hook permissions to include afterAddLiquidity, afterRemoveLiquidity, and afterSwap
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,  // Add this permission
            afterRemoveLiquidity: true, // Add this permission
            beforeSwap: true,
            afterSwap: true,  // Add this permission
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
