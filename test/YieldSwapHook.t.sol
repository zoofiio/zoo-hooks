// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
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
import {Math} from "openzeppelin/utils/math/Math.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol"; // Add ERC20 import
import {ZooCustomAccounting} from "src/base/ZooCustomAccounting.sol";

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
    uint256 constant SWAP_AMOUNT = 10e18;
    uint256 constant LIQUIDITY_AMOUNT = 100e18;

    function setUp() public {
        // Make sure we can see console output
        console.log("setUp start");
        
        // Creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        console.log("Managers and routers deployed");
        
        deployMintAndApprove2Currencies();
        console.log("Currencies deployed and approved");
        
        deployAndApprovePosm(manager);
        console.log("POSM deployed and approved");
        
        // Deploy the hook to an address with the correct flags
        // Updated hook flags to match the latest implementation
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG // Added AFTER_SWAP_FLAG for reserve tracking
            ) ^ (0x5555 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("YieldSwapHook.sol:YieldSwapHook", constructorArgs, flags);
        hook = YieldSwapHook(flags);
        console.log("Hook deployed at:", address(hook));
        
        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        console.log("Pool initialized");
        
        // Approve tokens for the hook - Fixed to unwrap Currency to address first
        // Skip approval for native ETH (which has address 0)
        if (!currency0.isAddressZero()) {
            ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        }
        if (!currency1.isAddressZero()) {
            ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        }
        
        // Add initial liquidity directly via the hook rather than PositionManager
        // This aligns with our new implementation
        _addInitialLiquidity();
    }
    
    function _addInitialLiquidity() internal {
        // Add initial liquidity using the hook's addLiquidity function
        // Fixed: Using ZooCustomAccounting's structs instead of trying to reference through YieldSwapHook
        ZooCustomAccounting.AddLiquidityParams memory params = ZooCustomAccounting.AddLiquidityParams({
            amount0Desired: LIQUIDITY_AMOUNT,
            amount1Desired: LIQUIDITY_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            to: address(this),
            deadline: block.timestamp + 60,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            salt: bytes32(0)
        });
        
        hook.addLiquidity(params);
        
        // Check that the liquidity shares were minted correctly
        uint256 lpTokenBalance = hook.balanceOf(address(this));
        console.log("Initial LP token balance:", lpTokenBalance);
        
        // Check reserves after adding initial liquidity
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        console.log("Initial reserveSY:", reserveSY);
        console.log("Initial reservePT:", reservePT);
    }

    function testOwnerFunctions() public {
        // Test setting pool parameters
        uint256 newRateScalar = 200; // Double the default value
        int256 newRateAnchor = 0.2e18; // Different anchor value

        // Should fail when called by non-owner
        vm.prank(address(1));
        vm.expectRevert(YieldSwapHook.OnlyOwner.selector);
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Should succeed when called by owner
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Test transferring ownership
        address newOwner = address(2);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner);

        // Should fail when called by old owner
        vm.expectRevert(YieldSwapHook.OnlyOwner.selector);
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);

        // Should succeed when called by new owner
        vm.prank(newOwner);
        hook.setPoolParameters(key, newRateScalar, newRateAnchor);
    }

    function testMinimumLiquidity() public {
        // Create a new pool to test MINIMUM_LIQUIDITY
        address token3 = address(new MockERC20("Token3", "TKN3"));
        address token4 = address(new MockERC20("Token4", "TKN4"));
        Currency currency3 = Currency.wrap(token3);
        Currency currency4 = Currency.wrap(token4);
        
        // Mint tokens
        deal(token3, address(this), 1000e18);
        deal(token4, address(this), 1000e18);
        
        // Approve tokens - Fixed to use underlying ERC20 tokens directly
        MockERC20(token3).approve(address(manager), type(uint256).max);
        MockERC20(token4).approve(address(manager), type(uint256).max);
        MockERC20(token3).approve(address(hook), type(uint256).max);
        MockERC20(token4).approve(address(hook), type(uint256).max);
        
        // Create new pool with hook
        PoolKey memory newKey = PoolKey(currency3, currency4, 3000, 60, IHooks(hook));
        manager.initialize(newKey, SQRT_PRICE_1_1);
        
        // Add liquidity with a new provider - Fixed parameter type
        ZooCustomAccounting.AddLiquidityParams memory params = ZooCustomAccounting.AddLiquidityParams({
            amount0Desired: 100e18,
            amount1Desired: 100e18,
            amount0Min: 0,
            amount1Min: 0,
            to: address(this),
            deadline: block.timestamp + 60,
            tickLower: TickMath.minUsableTick(newKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(newKey.tickSpacing),
            salt: bytes32(0)
        });
        
        hook.addLiquidity(params);
        
        // Check that MINIMUM_LIQUIDITY was sent to address(0)
        uint256 minimumLiquidity = hook.MINIMUM_LIQUIDITY();
        assertEq(hook.balanceOf(address(0)), minimumLiquidity);
        
        // Calculate expected liquidity: sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
        uint256 expectedLiquidity = Math.sqrt(params.amount0Desired * params.amount1Desired) - minimumLiquidity;
        assertEq(hook.balanceOf(address(this)), expectedLiquidity);
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
        
        // Since amount1 is positive (we receive PT tokens)
        uint256 actualOutput = uint256(int256(swapDelta.amount1()));
        console.log("testSwapSYToPT, actualOutput:", actualOutput);
        console.log("testSwapSYToPT, expectedOutput:", expectedOutput);
        assertEq(actualOutput, expectedOutput, "Actual output should match expected");
        
        // Check final reserves
        (uint256 finalReserveSY, uint256 finalReservePT) = hook.getReserves(key);
        assertEq(finalReserveSY, initialReserveSY + SWAP_AMOUNT, "SY reserves should increase by swap amount");
        assertEq(finalReservePT, initialReservePT - expectedOutput, "PT reserves should decrease by output amount");
    }

    function testFailSwapPTToSY() public {
        // This should fail as we only support SY to PT swaps
        bool zeroForOne = false; // PT to SY
        int256 amountSpecified = -int256(SWAP_AMOUNT);
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testFailExactOutputSwap() public {
        // This should fail as we only support exact input swaps
        bool zeroForOne = true; // SY to PT
        int256 amountSpecified = int256(SWAP_AMOUNT); // positive for exact output
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testAddAndRemoveLiquidity() public {
        // Get initial state
        uint256 initialLpTokens = hook.balanceOf(address(this));
        (uint256 initialReserveSY, uint256 initialReservePT) = hook.getReserves(key);
        
        // Add more liquidity - Fixed parameter type
        ZooCustomAccounting.AddLiquidityParams memory addParams = ZooCustomAccounting.AddLiquidityParams({
            amount0Desired: 50e18,
            amount1Desired: 50e18, 
            amount0Min: 0,
            amount1Min: 0,
            to: address(this),
            deadline: block.timestamp + 60,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            salt: bytes32(0)
        });
        
        hook.addLiquidity(addParams);
        
        // Check state after adding liquidity
        uint256 midLpTokens = hook.balanceOf(address(this));
        (uint256 midReserveSY, uint256 midReservePT) = hook.getReserves(key);
        
        assertEq(midReserveSY, initialReserveSY + addParams.amount0Desired, "SY reserves should increase correctly");
        assertEq(midReservePT, initialReservePT + addParams.amount1Desired, "PT reserves should increase correctly");
        
        // For V2-style liquidity math with existing liquidity:
        // liquidity = min(amount0 * totalSupply / reserve0, amount1 * totalSupply / reserve1)
        uint256 expectedNewLpTokens = Math.min(
            (addParams.amount0Desired * initialLpTokens) / initialReserveSY,
            (addParams.amount1Desired * initialLpTokens) / initialReservePT
        );
        assertEq(midLpTokens - initialLpTokens, expectedNewLpTokens, "LP tokens should increase correctly");
        
        // Now remove half of the liquidity
        uint256 lpTokensToRemove = expectedNewLpTokens / 2;
        
        ZooCustomAccounting.RemoveLiquidityParams memory removeParams = ZooCustomAccounting.RemoveLiquidityParams({
            liquidity: lpTokensToRemove,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 60,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            salt: bytes32(0)
        });
        
        // Approve hook to spend our LP tokens
        hook.approve(address(hook), lpTokensToRemove);
        
        hook.removeLiquidity(removeParams);
        
        // Check final state
        uint256 finalLpTokens = hook.balanceOf(address(this));
        (uint256 finalReserveSY, uint256 finalReservePT) = hook.getReserves(key);
        
        assertEq(finalLpTokens, midLpTokens - lpTokensToRemove, "LP tokens should decrease correctly");
        
        // Expected amounts to be removed based on proportional share:
        uint256 expectedSYRemoved = (midReserveSY * lpTokensToRemove) / midLpTokens;
        uint256 expectedPTRemoved = (midReservePT * lpTokensToRemove) / midLpTokens;
        
        assertEq(finalReserveSY, midReserveSY - expectedSYRemoved, "SY reserves should decrease correctly");
        assertEq(finalReservePT, midReservePT - expectedPTRemoved, "PT reserves should decrease correctly");
    }

    function testPriceImpact() public view {
        // Small swap should have minimal price impact
        uint256 smallAmount = 1e18;
        uint256 smallQuote = hook.getQuote(key, smallAmount);
        uint256 smallRate = (smallQuote * 1e18) / smallAmount;
        
        // Large swap should have more price impact
        uint256 largeAmount = 100e18;
        uint256 largeQuote = hook.getQuote(key, largeAmount);
        uint256 largeRate = (largeQuote * 1e18) / largeAmount;
        
        // Due to the curve formula, larger swaps should have worse rates (less PT per SY)
        assert(largeRate < smallRate);
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
            assertEq(reserveSYAfter, reserveSYBefore + swapSize, "SY reserves should increase correctly");
            
            uint256 actualOutput = uint256(int256(delta.amount1()));
            assertEq(reservePTAfter, reservePTBefore - actualOutput, "PT reserves should decrease by output amount");
            assertEq(actualOutput, quote, "Actual output should match quoted amount");
        }
    }
    
    function testRemoveAllLiquidity() public {
        uint256 lpTokens = hook.balanceOf(address(this));
        
        // Approve hook to spend our LP tokens
        hook.approve(address(hook), lpTokens);
        
        // Remove all liquidity - Fixed parameter type
        ZooCustomAccounting.RemoveLiquidityParams memory removeParams = ZooCustomAccounting.RemoveLiquidityParams({
            liquidity: lpTokens,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 60,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            salt: bytes32(0)
        });
        
        hook.removeLiquidity(removeParams);
        
        // Check final state
        uint256 finalLpTokens = hook.balanceOf(address(this));
        (uint256 finalReserveSY, uint256 finalReservePT) = hook.getReserves(key);
        
        assertEq(finalLpTokens, 0, "All LP tokens should be burned");
        // There might still be some dust amounts in reserves
        assertLt(finalReserveSY, 10, "SY reserves should be nearly zero");
        assertLt(finalReservePT, 10, "PT reserves should be nearly zero");
    }
}

// Mock ERC20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
