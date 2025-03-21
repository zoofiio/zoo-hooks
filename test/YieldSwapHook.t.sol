// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {YieldSwapHook} from "../src/YieldSwapHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract YieldSwapHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    YieldSwapHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Constants for testing
    uint256 constant INITIAL_SY_LIQUIDITY = 1000e18;
    uint256 constant INITIAL_PT_LIQUIDITY = 500e18;
    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        // Creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5555 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("YieldSwapHook.sol:YieldSwapHook", constructorArgs, flags);
        hook = YieldSwapHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // Add initial liquidity to the pool - SY is currency0, PT is currency1
        // Fix: Add the missing bytes parameter for hook data
        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            INITIAL_SY_LIQUIDITY,
            INITIAL_PT_LIQUIDITY,
            address(this),
            block.timestamp,
            "" // Empty bytes for hook data
        );
    }

    function testInitialization() public {
        // Check that the pool was initialized with default parameters
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        assertEq(reserveSY, INITIAL_SY_LIQUIDITY);
        assertEq(reservePT, INITIAL_PT_LIQUIDITY);
    }

    function testOwnerFunctions() public {
        // Test setting pool parameters
        uint256 newRateScalar = 200; // Double the default value
        int256 newRateAnchor = 0.2e18; // Double the default value

        // Should fail when called by non-owner
        vm.prank(address(1));
        vm.expectRevert(abi.encodeWithSignature("OnlyOwner()"));
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Should succeed when called by owner
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Test transferring ownership
        address newOwner = address(2);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner);

        // Should fail when called by old owner
        vm.expectRevert(abi.encodeWithSignature("OnlyOwner()"));
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Should succeed when called by new owner
        vm.prank(newOwner);
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);
    }

    function testSwapSYToPT() public {
        // Get initial reserves
        (uint256 initialReserveSY, uint256 initialReservePT) = hook.getReserves(key);
        
        // Quote first to see expected output
        uint256 expectedOutput = hook.getQuote(key, SWAP_AMOUNT);
        
        // Perform swap - SY to PT (zeroForOne = true)
        bool zeroForOne = true;
        int256 amountSpecified = -int256(SWAP_AMOUNT); // negative for exact input
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Check the swap delta
        assertEq(swapDelta.amount0(), amountSpecified); // Should have spent exactly SWAP_AMOUNT of SY
        
        // Since amount1 is positive (we receive PT tokens), convert to uint256 safely
        uint256 actualOutput = uint256(uint128(swapDelta.amount1()));
        assertEq(actualOutput, expectedOutput); // Should match our quote
        
        // Check final reserves
        (uint256 finalReserveSY, uint256 finalReservePT) = hook.getReserves(key);
        assertEq(finalReserveSY, initialReserveSY + SWAP_AMOUNT);
        assertEq(finalReservePT, initialReservePT - expectedOutput);
    }

    function testFailSwapPTToSY() public {
        // This should fail as we only support SY to PT swaps
        bool zeroForOne = false; // PT to SY
        int256 amountSpecified = -int256(SWAP_AMOUNT);
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testQuoteAccuracy() public {
        // Get quote for swap
        uint256 quoteAmount = hook.getQuote(key, SWAP_AMOUNT);
        
        // Perform the actual swap
        bool zeroForOne = true;
        int256 amountSpecified = -int256(SWAP_AMOUNT);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // The actual output should match our quote (safely convert int128 to uint256)
        uint256 actualOutput = uint256(uint128(swapDelta.amount1()));
        assertEq(actualOutput, quoteAmount);
    }

    function testLiquidityTracking() public {
        // Add more liquidity
        uint128 additionalLiquidity = 50e18;
        uint256 additionalSY = 500e18;
        uint256 additionalPT = 250e18;
        
        (uint256 initialReserveSY, uint256 initialReservePT) = hook.getReserves(key);
        
        // Fix: Add the missing bytes parameter for hook data
        posm.increaseLiquidity(
            tokenId,
            additionalLiquidity,
            additionalSY,
            additionalPT,
            block.timestamp,
            "" // Empty bytes for hook data
        );
        
        // Check reserves after adding liquidity
        (uint256 midReserveSY, uint256 midReservePT) = hook.getReserves(key);
        assertEq(midReserveSY, initialReserveSY + additionalSY);
        assertEq(midReservePT, initialReservePT + additionalPT);
        
        // Fix: Add the missing bytes parameter for hook data
        posm.decreaseLiquidity(
            tokenId,
            additionalLiquidity,
            0, // Min tokens out
            0, // Min tokens out
            address(this),
            block.timestamp,
            "" // Empty bytes for hook data
        );
        
        // Check reserves after removing liquidity
        (uint256 finalReserveSY, uint256 finalReservePT) = hook.getReserves(key);
        assertApproxEqRel(finalReserveSY, initialReserveSY, 0.01e18); // Allow 1% error margin due to fees
        assertApproxEqRel(finalReservePT, initialReservePT, 0.01e18);
    }

    function testPriceImpact() public {
        // Small swap should have minimal price impact
        uint256 smallAmount = 1e18;
        uint256 smallQuote = hook.getQuote(key, smallAmount);
        uint256 smallRate = (smallQuote * 1e18) / smallAmount;
        
        // Large swap should have more price impact
        uint256 largeAmount = 1000e18;
        uint256 largeQuote = hook.getQuote(key, largeAmount);
        uint256 largeRate = (largeQuote * 1e18) / largeAmount;
        
        // Due to the curve formula, larger swaps should have worse rates (less PT per SY)
        assertLt(largeRate, smallRate);
    }

    function testMultipleSwaps() public {
        // Do multiple swaps and verify each one changes the reserves correctly
        for (uint i = 0; i < 5; i++) {
            uint256 swapSize = SWAP_AMOUNT / 5;
            
            (uint256 reserveSYBefore, uint256 reservePTBefore) = hook.getReserves(key);
            uint256 quote = hook.getQuote(key, swapSize);
            
            bool zeroForOne = true;
            int256 amountSpecified = -int256(swapSize);
            BalanceDelta delta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
            
            (uint256 reserveSYAfter, uint256 reservePTAfter) = hook.getReserves(key);
            
            // Verify reserves were updated correctly
            assertEq(reserveSYAfter, reserveSYBefore + swapSize);
            
            // Safely convert int128 amount1 to uint256 for the assertion
            uint256 actualOutput = uint256(uint128(delta.amount1()));
            assertEq(reservePTAfter, reservePTBefore - actualOutput);
            assertEq(actualOutput, quote);
        }
    }
}
