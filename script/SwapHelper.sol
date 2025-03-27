// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/**
 * @title SwapHelper
 * @notice Helper contract to perform swaps through Uniswap V4 PoolManager
 * @dev Implements the unlock/callback pattern required by Uniswap V4
 */
contract SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    
    struct SwapCallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
    }
    
    IPoolManager public immutable poolManager;
    
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
    
    /**
     * @notice Performs a swap through the Uniswap V4 PoolManager
     * @param key The pool key for the pool to swap in
     * @param params The swap parameters
     * @param recipient The address to receive the output tokens
     * @return delta The balance delta from the swap
     */
    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        address recipient
    ) external returns (BalanceDelta delta) {
        // Approve tokens to pool manager if needed
        if (params.amountSpecified > 0) {
            // This is an exact input swap
            Currency currency = params.zeroForOne ? key.currency0 : key.currency1;
            uint256 amount = uint256(params.amountSpecified);
            
            // Transfer tokens from sender to this contract
            IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
            
            // Approve pool manager to take tokens
            IERC20(Currency.unwrap(currency)).approve(address(poolManager), amount);
        }
        
        // Pack the callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            sender: msg.sender,
            key: key,
            params: params
        });
        
        // Unlock and perform the swap via callback pattern
        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Transfer any output tokens to recipient
        if (params.zeroForOne && delta.amount1() < 0) {
            // Received token1
            // Convert negative int128 to uint256 safely
            uint256 amount = uint256(uint128(-delta.amount1()));
            poolManager.take(key.currency1, recipient, amount);
        } else if (!params.zeroForOne && delta.amount0() < 0) {
            // Received token0
            // Convert negative int128 to uint256 safely
            uint256 amount = uint256(uint128(-delta.amount0()));
            poolManager.take(key.currency0, recipient, amount);
        }
        
        return delta;
    }
    
    /**
     * @notice Called by PoolManager.unlock() to perform the actual swap
     * @param data The encoded callback data
     * @return The encoded balance delta from the swap
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        
        SwapCallbackData memory callbackData = abi.decode(data, (SwapCallbackData));
        
        // Track balance deltas before the swap
        (,, int256 deltaBefore0) = _fetchBalances(callbackData.key.currency0, callbackData.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(callbackData.key.currency1, callbackData.sender, address(this));
        
        // Perform the actual swap
        BalanceDelta delta = poolManager.swap(callbackData.key, callbackData.params, "");
        
        // Track balance deltas after the swap to know what needs settling
        (,, int256 deltaAfter0) = _fetchBalances(callbackData.key.currency0, callbackData.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(callbackData.key.currency1, callbackData.sender, address(this));
        
        // Use CurrencySettler to handle settlements properly
        // If delta is negative, we need to settle (tokens flowing from contract to pool)
        if (deltaAfter0 < 0) {
            callbackData.key.currency0.settle(poolManager, callbackData.sender, uint256(-deltaAfter0), false);
        }
        if (deltaAfter1 < 0) {
            callbackData.key.currency1.settle(poolManager, callbackData.sender, uint256(-deltaAfter1), false);
        }
        
        // If delta is positive, we need to take (tokens flowing from pool to contract)
        if (deltaAfter0 > 0) {
            callbackData.key.currency0.take(poolManager, callbackData.sender, uint256(deltaAfter0), false);
        }
        if (deltaAfter1 > 0) {
            callbackData.key.currency1.take(poolManager, callbackData.sender, uint256(deltaAfter1), false);
        }
        
        return abi.encode(delta);
    }
    
    /**
     * @notice Helper function to fetch balances for a given currency
     * @param currency The currency to fetch balances for
     * @param user The user address to check balances for
     * @param deltaHolder The address that holds the delta
     * @return userBalance The balance of the user
     * @return poolBalance The balance in the pool
     * @return delta The delta for the currency
     */
    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(poolManager));
        delta = poolManager.currencyDelta(deltaHolder, currency);
    }
}
