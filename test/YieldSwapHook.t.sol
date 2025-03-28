// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {YieldSwapHook} from "src/YieldSwapHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ZooCustomAccounting} from "src/base/ZooCustomAccounting.sol";
import {Protocol} from "src/Protocol.sol";

contract YieldSwapHookTest is Test, Deployers {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    // Update event signature to match the contract
    event ParametersUpdated(uint256 epochStart, uint256 epochDuration);
    event ReservesUpdated(uint256 reserveSY, uint256 reservePT);

    Protocol protocol;
    YieldSwapHook hook;

    uint256 constant MAX_DEADLINE = 12329839823;

    // Minimum and maximum ticks for a spacing of 60
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    PoolId id;

    // Epoch-related constants for testing
    uint256 DEFAULT_EPOCH_START; 
    uint256 constant DEFAULT_EPOCH_DURATION = 7 days; // 1 week duration

    function setUp() public {
        deployFreshManagerAndRouters();

        DEFAULT_EPOCH_START = block.timestamp;
        protocol = new Protocol();
        hook = YieldSwapHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                )
            )
        );
        // Updated constructor call with epoch parameters
        deployCodeTo("src/YieldSwapHook.sol:YieldSwapHook", 
            abi.encode(address(protocol), manager, DEFAULT_EPOCH_START, DEFAULT_EPOCH_DURATION), 
            address(hook));

        deployMintAndApprove2Currencies();
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.label(Currency.unwrap(currency0), "SY_Token");
        vm.label(Currency.unwrap(currency1), "PT_Token");
    }

    function test_beforeInitialize_poolKey_succeeds() public view {
        (Currency _currency0, Currency _currency1, uint24 _fee, int24 _tickSpacing, IHooks _hooks) = hook.poolKey();

        assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1));
        assertEq(_fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(_tickSpacing, 60);
        assertEq(address(_hooks), address(hook));
    }

    function test_initialize_already_reverts() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function test_initial_state() public view {
        // Verify initial liquidity and reserves are zero
        assertEq(hook.totalSupply(), 0);
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        assertEq(reserveSY, 0);
        assertEq(reservePT, 0);
        
        // Verify owner
        assertEq(hook.owner(), address(this));

        // Verify epoch parameters
        assertEq(hook.epochStart(), DEFAULT_EPOCH_START);
        assertEq(hook.epochDuration(), DEFAULT_EPOCH_DURATION);
    }

    // Test add liquidity functionality
    function test_addLiquidity_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        ZooCustomAccounting.AddLiquidityParams memory addLiquidityParams = ZooCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        hook.addLiquidity(addLiquidityParams);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        uint256 minimumLiquidity = hook.MINIMUM_LIQUIDITY();

        // Verify token balances decreased
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        // Verify received liquidity tokens (minus minimum liquidity)
        // Using approximate comparison, allowing small errors
        assertApproxEqAbs(liquidityTokenBal, 10 ether - minimumLiquidity, 2000);
        
        // Verify total liquidity
        // totalSupply should also be close to 10 ether, but may have small errors
        assertApproxEqAbs(hook.totalSupply(), 10 ether - minimumLiquidity + minimumLiquidity, 2000);
        
        // Verify reserves update
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        console.log("reserveSY: ", reserveSY);
        console.log("reservePT: ", reservePT);
        assertEq(reserveSY, 10 ether);
        assertEq(reservePT, 10 ether);
    }
    
    function test_addLiquidity_fuzz_succeeds(uint112 amount) public {
        // Ensure amount is large enough to avoid underflow with minimumLiquidity (1000)
        vm.assume(amount > 10000 && amount < 1_000_000 ether); // Minimum 10000 to avoid underflow issues

        ZooCustomAccounting.AddLiquidityParams memory addLiquidityParams = ZooCustomAccounting.AddLiquidityParams(
            amount, amount, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        hook.addLiquidity(addLiquidityParams);
        
        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        uint256 minimumLiquidity = hook.MINIMUM_LIQUIDITY();
        
        // For larger amounts, use relative comparison instead of absolute
        if (amount > 100 ether) {
            // For large amounts, 0.1% relative tolerance is fine
            assertApproxEqRel(liquidityTokenBal, amount - minimumLiquidity, 0.001e18);
        } else {
            // For smaller amounts, use absolute tolerance, but ensure it's proportional to the amount
            uint256 tolerance = amount / 100; // 1% of amount as tolerance
            tolerance = tolerance < 2000 ? 2000 : tolerance; // Minimum tolerance of 2000
            assertApproxEqAbs(liquidityTokenBal, amount - minimumLiquidity, tolerance);
        }
        
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        assertEq(reserveSY, amount);
        assertEq(reservePT, amount);
    }

    function test_addLiquidity_multiple_succeeds() public {
        // First liquidity addition
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 liquidityBal1 = hook.balanceOf(address(this));
        uint256 minimumLiquidity = hook.MINIMUM_LIQUIDITY();
        
        // Using approximate comparison, allowing small errors
        assertApproxEqAbs(liquidityBal1, 10 ether - minimumLiquidity, 2000);
        
        // Second liquidity addition
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                5 ether, 5 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 liquidityBal2 = hook.balanceOf(address(this));
        
        // Added 5 tokens, should get 5 liquidity tokens (since ratio is 1:1)
        // Using approximate comparison, allowing small errors
        assertApproxEqAbs(liquidityBal2 - liquidityBal1, 5 ether, 2000);
        
        // Verify token balances
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 5 ether);
        
        // Verify reserves
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        assertEq(reserveSY, 15 ether);
        assertEq(reservePT, 15 ether);
    }

    function test_addLiquidity_expired_revert() public {
        vm.expectRevert(ZooCustomAccounting.ExpiredPastDeadline.selector);
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, address(this), block.timestamp - 1, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }
    
    function test_addLiquidity_tooMuchSlippage_reverts() public {
        vm.expectRevert(ZooCustomAccounting.TooMuchSlippage.selector);
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether,
                10 ether,
                100 ether,
                100 ether,
                address(this),
                MAX_DEADLINE,
                MIN_TICK,
                MAX_TICK,
                bytes32(0)
            )
        );
    }

    function test_removeLiquidity_partial_succeeds() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 initialLiquidity = hook.balanceOf(address(this));
        
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        
        hook.removeLiquidity(
            ZooCustomAccounting.RemoveLiquidityParams(
                initialLiquidity / 2, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 remainingLiquidity = hook.balanceOf(address(this));
        
        assertEq(remainingLiquidity, initialLiquidity - initialLiquidity / 2);
        
        assertApproxEqAbs(key.currency0.balanceOf(address(this)), prevBalance0 + 5 ether, 2000);
        assertApproxEqAbs(key.currency1.balanceOf(address(this)), prevBalance1 + 5 ether, 2000);
        
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        assertApproxEqAbs(reserveSY, 5 ether, 2000);
        assertApproxEqAbs(reservePT, 5 ether, 2000);
    }
    
    function test_removeLiquidity_full_succeeds() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        
        hook.removeLiquidity(
            ZooCustomAccounting.RemoveLiquidityParams(
                liquidityTokenBal, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        assertEq(hook.balanceOf(address(this)), 0);
        
        uint256 actualReturn0 = key.currency0.balanceOf(address(this)) - prevBalance0;
        uint256 actualReturn1 = key.currency1.balanceOf(address(this)) - prevBalance1;
        
        console.log("Actual token0 returned:", actualReturn0);
        console.log("Actual token1 returned:", actualReturn1);
        // console.log("Compared to expected 10 ether:", 10 ether);
        
        assertApproxEqRel(
            key.currency0.balanceOf(address(this)),
            prevBalance0 + 10 ether,
            0.05e18
        );
        assertApproxEqRel(
            key.currency1.balanceOf(address(this)),
            prevBalance1 + 10 ether,
            0.05e18
        );
        
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(key);
        console.log("reserveSY: ", reserveSY);
        console.log("reservePT: ", reservePT);
        
        uint256 minLiquidity = hook.MINIMUM_LIQUIDITY();
        assertLe(reserveSY, minLiquidity + 10); 
        assertLe(reservePT, minLiquidity + 10);
    }
    
    function test_removeLiquidity_tooMuchSlippage_reverts() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        
        vm.expectRevert(ZooCustomAccounting.TooMuchSlippage.selector);
        hook.removeLiquidity(
            ZooCustomAccounting.RemoveLiquidityParams(
                liquidityTokenBal, 20 ether, 20 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }
    
    function test_removeLiquidity_fuzz_succeeds(uint112 addAmount, uint112 removeAmount) public {
        // Increase minimum amount to avoid underflow issues with small values
        vm.assume(addAmount > 10000000 && addAmount < 1_000_000 ether); // Match minimum from add liquidity test
        
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                addAmount, addAmount, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        
        uint256 actualRemoveAmount = bound(removeAmount, 1000, uint112(liquidityTokenBal));
        
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        
        hook.removeLiquidity(
            ZooCustomAccounting.RemoveLiquidityParams(
                actualRemoveAmount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        assertEq(hook.balanceOf(address(this)), liquidityTokenBal - actualRemoveAmount);
        
        uint256 token0Received = key.currency0.balanceOf(address(this)) - prevBalance0;
        uint256 token1Received = key.currency1.balanceOf(address(this)) - prevBalance1;
        
        assertTrue(token0Received > 0, "Should receive token0");
        assertTrue(token1Received > 0, "Should receive token1");
        
        // For proportion verification, use approximate comparison with tolerance
        if (actualRemoveAmount > liquidityTokenBal / 2) {
            // Calculate expected amount proportionally based on liquidity removed
            uint256 expectedAmount = (addAmount * actualRemoveAmount) / liquidityTokenBal;
            
            // Give a 2% margin for rounding errors
            uint256 tolerance = expectedAmount * 2 / 100;
            
            // Debug logs
            console.log("Bound result", actualRemoveAmount);
            console.log("addAmount: ", addAmount);
            console.log("Expected (proportional): ", expectedAmount);
            console.log("Token0 received: ", token0Received);
            console.log("Token1 received: ", token1Received);
            
            // Use approximate comparison instead of strict greater than
            assertApproxEqAbs(token0Received, expectedAmount, tolerance);
            assertApproxEqAbs(token1Received, expectedAmount, tolerance);
        }
    }
    
    function test_swap_SY_to_PT_succeeds() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        console.log("SY balance before swap: ", prevBalance0);
        console.log("PT balance before swap: ", prevBalance1);
        
        (uint256 reserveSYBefore, uint256 reservePTBefore) = hook.getReserves(key);
        
        uint256 syAmount = 10 ether;
        uint256 expectedPTAmount = hook.getQuote(key, syAmount);
        console.log("Expected PT amount: ", expectedPTAmount);
        
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(syAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        
        console.log("SY balance after swap: ", key.currency0.balanceOf(address(this)));
        console.log("PT balance after swap: ", key.currency1.balanceOf(address(this)));
        console.log("SY balance change: ", prevBalance0 - key.currency0.balanceOf(address(this)));
        console.log("PT balance change: ", key.currency1.balanceOf(address(this)) - prevBalance1);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - syAmount);

        assertApproxEqRel(
            key.currency1.balanceOf(address(this)) - prevBalance1,
            expectedPTAmount,
            1e15
        );
        
        console.log("Reserve SY before swap: ", reserveSYBefore);
        console.log("Reserve PT before swap: ", reservePTBefore);
        (uint256 reserveSYAfter, uint256 reservePTAfter) = hook.getReserves(key);
        console.log("Reserve SY after swap: ", reserveSYAfter);
        console.log("Reserve PT after swap: ", reservePTAfter);
        assertEq(reserveSYAfter, reserveSYBefore + syAmount);
        assertEq(reservePTAfter, reservePTBefore - (key.currency1.balanceOf(address(this)) - prevBalance1));
    }
    
    function test_swap_PT_to_SY_succeeds() public {
        // Add liquidity
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 prevBalance0 = key.currency0.balanceOf(address(this)); // SY balance
        uint256 prevBalance1 = key.currency1.balanceOf(address(this)); // PT balance
        console.log("SY balance before swap: ", prevBalance0);
        console.log("PT balance before swap: ", prevBalance1);
        
        (uint256 reserveSYBefore, uint256 reservePTBefore) = hook.getReserves(key);
        console.log("Reserve SY before swap: ", reserveSYBefore);
        console.log("Reserve PT before swap: ", reservePTBefore);
        
        // Swap PT to SY (10 PT tokens)
        uint256 ptAmount = 10 ether;
        
        // Get expected SY amount using the new helper function
        uint256 expectedSYAmount = hook.getQuotePTtoSY(ptAmount);
        console.log("Expected SY amount: ", expectedSYAmount);
        
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({
                zeroForOne: false, // This is the key difference - now swapping PT to SY (false = token1 to token0)
                amountSpecified: -int256(ptAmount), // Negative for exact input swap
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // Use max price limit for PT to SY swaps
            });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        
        console.log("SY balance after swap: ", key.currency0.balanceOf(address(this)));
        console.log("PT balance after swap: ", key.currency1.balanceOf(address(this)));
        console.log("SY balance change: ", key.currency0.balanceOf(address(this)) - prevBalance0);
        console.log("PT balance change: ", prevBalance1 - key.currency1.balanceOf(address(this)));
        
        // Verify that PT decreased by the expected amount
        assertEq(prevBalance1 - key.currency1.balanceOf(address(this)), ptAmount);
        
        // Verify that SY increased by approximately the expected amount
        assertApproxEqRel(
            key.currency0.balanceOf(address(this)) - prevBalance0,
            expectedSYAmount,
            0.01e18 // 1% tolerance
        );
        
        // Verify reserves were updated correctly
        (uint256 reserveSYAfter, uint256 reservePTAfter) = hook.getReserves(key);
        console.log("Reserve SY after swap: ", reserveSYAfter);
        console.log("Reserve PT after swap: ", reservePTAfter);
        
        uint256 syDelta = reserveSYBefore - reserveSYAfter;
        uint256 ptDelta = reservePTAfter - reservePTBefore;
        
        assertEq(ptDelta, ptAmount, "PT reserves should increase by the exact input amount");
        assertEq(syDelta, key.currency0.balanceOf(address(this)) - prevBalance0, "SY reserves should decrease by the output amount");
    }
    
    // Test PT to SY with exact output (user specifies exact SY amount to receive)
    function test_swap_PT_to_SY_exactOutput_succeeds() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        // Desired SY output amount
        uint256 desiredSYAmount = 5 ether;
        
        uint256 prevBalance0 = key.currency0.balanceOf(address(this)); // SY balance
        uint256 prevBalance1 = key.currency1.balanceOf(address(this)); // PT balance
        
        // Get the required PT input for the desired SY output using the helper function
        uint256 expectedPTInput = hook.getRequiredPTforSY(desiredSYAmount);
        console.log("Expected PT input for desired SY:", expectedPTInput);
        
        (uint256 reserveSYBefore, uint256 reservePTBefore) = hook.getReserves(key);
        
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({
                zeroForOne: false, // PT to SY (token1 to token0)
                amountSpecified: int256(desiredSYAmount), // Positive for exact output swap
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        
        uint256 actualPTSpent = prevBalance1 - key.currency1.balanceOf(address(this));
        uint256 actualSYReceived = key.currency0.balanceOf(address(this)) - prevBalance0;
        
        console.log("PT spent:", actualPTSpent);
        console.log("SY received:", actualSYReceived);
        
        // Verify we received exactly the SY amount requested
        assertEq(actualSYReceived, desiredSYAmount, "Should receive exactly the requested SY amount");
        
        // Verify the PT spent is close to the predicted amount
        assertApproxEqRel(actualPTSpent, expectedPTInput, 0.01e18, "Actual PT spent should be close to predicted amount");
        
        // Verify reserves were updated correctly
        (uint256 reserveSYAfter, uint256 reservePTAfter) = hook.getReserves(key);
        assertEq(reserveSYAfter, reserveSYBefore - desiredSYAmount);
        assertEq(reservePTAfter, reservePTBefore + actualPTSpent);
    }
    
    // Test PT to SY swap pricing over time
    function test_swap_PT_to_SY_across_time() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                500 ether, 500 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        // Amount of PT to swap
        uint256 ptAmount = 10 ether;
        
        // Get quote at beginning of epoch
        uint256 quoteStart = hook.getQuotePTtoSY(ptAmount);
        
        // Time travel to middle of epoch
        vm.warp(DEFAULT_EPOCH_START + DEFAULT_EPOCH_DURATION / 2);
        
        // Get quote at middle of epoch
        uint256 quoteMid = hook.getQuotePTtoSY(ptAmount);
        
        // Time travel to end of epoch
        vm.warp(DEFAULT_EPOCH_START + DEFAULT_EPOCH_DURATION);
        
        // Get quote at end of epoch
        uint256 quoteEnd = hook.getQuotePTtoSY(ptAmount);
        
        console.log("SY quote at start:", quoteStart);
        console.log("SY quote at middle:", quoteMid);
        console.log("SY quote at end:", quoteEnd);
        
        // As time progresses, PT becomes worth more SY (inverse of the SY to PT price movement)
        assertTrue(quoteMid > quoteStart, "SY amount should increase as time passes");
        assertTrue(quoteEnd > quoteMid, "SY amount should increase as time passes");
    }
    
    // Test comparing PT to SY and SY to PT swap rates
    function test_compare_PT_to_SY_and_SY_to_PT_rates() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 amount = 1 ether; // Use a small amount to minimize price impact
        
        // Get quotes for both directions
        uint256 ptFromSY = hook.getQuote(key, amount);
        uint256 syFromPT = hook.getQuotePTtoSY(amount);
        
        console.log("1 SY gets you (PT):", ptFromSY);
        console.log("1 PT gets you (SY):", syFromPT);
        
        // Calculate effective rates
        uint256 syToPtRate = (ptFromSY * 1e18) / amount;
        uint256 ptToSyRate = (syFromPT * 1e18) / amount;
        
        console.log("SY to PT rate:", syToPtRate);
        console.log("PT to SY rate:", ptToSyRate);
        
        // In a perfect market with no price impact, the rates would be exact inverses
        // But due to price impact and calculation differences, we expect them to be close but not exact
        // Check that their product is close to 1e36 (1e18 * 1e18)
        uint256 rateProduct = (syToPtRate * ptToSyRate) / 1e18;
        console.log("Rate product (should be close to 1e18):", rateProduct);
        
        assertApproxEqRel(rateProduct, 1e18, 0.05e18, "Rates should be approximately inverse of each other");
    }
    
    // Test large PT to SY swap
    function test_large_PT_to_SY_swap() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                500 ether, 500 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        uint256 ptAmount = 100 ether;
        uint256 expectedSYAmount = hook.getQuotePTtoSY(ptAmount);
        console.log("Expected SY for 100 PT:", expectedSYAmount);
        
        uint256 prevSYBalance = key.currency0.balanceOf(address(this));
        
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({
                zeroForOne: false,  // PT to SY
                amountSpecified: -int256(ptAmount),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        
        uint256 actualSYReceived = key.currency0.balanceOf(address(this)) - prevSYBalance;
        console.log("Actually received SY:", actualSYReceived);
        
        // Verify we received close to the estimated amount
        assertApproxEqRel(actualSYReceived, expectedSYAmount, 0.01e18);
        
        // With a large swap, we should see significant price impact
        // Let's try another small swap to see the change in rate
        uint256 smallPtAmount = 1 ether;
        uint256 newExpectedSYAmount = hook.getQuotePTtoSY(smallPtAmount);
        console.log("New expected SY for 1 PT:", newExpectedSYAmount);
        
        // The rate should be worse now (less SY per PT) due to decreased SY reserves
        uint256 initialRate = expectedSYAmount * 1e18 / ptAmount; // SY per PT for first swap
        uint256 newRate = newExpectedSYAmount * 1e18 / smallPtAmount; // SY per PT for potential second swap
        
        console.log("Initial rate (SY/PT):", initialRate);
        console.log("New rate (SY/PT):", newRate);
        
        assertTrue(newRate < initialRate, "Rate should be worse after large swap");
    }
    
    // Test PT to SY exactOutput when insufficient SY reserves
    function test_PT_to_SY_exactOutput_insufficient_reserves_reverts() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                50 ether, 50 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        // Try to swap for more SY than is available in the pool
        uint256 desiredSYAmount = 51 ether;
        
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({
                zeroForOne: false,  // PT to SY
                amountSpecified: int256(desiredSYAmount), // Exact output
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        // Should revert with insufficient reserves error (wrapped by pool manager)
        vm.expectRevert();
        swapRouter.swap(key, params, settings, ZERO_BYTES);
    }
    
    // Test both swap directions in sequence
    function test_bidirectional_swaps_in_sequence() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        // Get initial balances
        uint256 initialSYBalance = key.currency0.balanceOf(address(this));
        uint256 initialPTBalance = key.currency1.balanceOf(address(this));
        
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        // First swap: SY to PT
        uint256 syToSwap = 10 ether;
        IPoolManager.SwapParams memory syToPtParams =
            IPoolManager.SwapParams({
                zeroForOne: true,  // SY to PT
                amountSpecified: -int256(syToSwap),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });
        
        swapRouter.swap(key, syToPtParams, settings, ZERO_BYTES);
        
        uint256 ptReceived = key.currency1.balanceOf(address(this)) - initialPTBalance;
        console.log("PT received from SY:", ptReceived);
        
        // Second swap: PT to SY
        IPoolManager.SwapParams memory ptToSyParams =
            IPoolManager.SwapParams({
                zeroForOne: false,  // PT to SY
                amountSpecified: -int256(ptReceived), // Swap back the exact amount we received
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            });
        
        swapRouter.swap(key, ptToSyParams, settings, ZERO_BYTES);
        
        // Check final balances
        uint256 finalSYBalance = key.currency0.balanceOf(address(this));
        uint256 finalPTBalance = key.currency1.balanceOf(address(this));
        
        console.log("SY spent initially:", syToSwap);
        console.log("SY recovered:", finalSYBalance - (initialSYBalance - syToSwap));
        console.log("PT balance change:", finalPTBalance - initialPTBalance);
        
        // Due to price impact, we should get less SY back than we initially put in
        assertTrue(finalSYBalance < initialSYBalance, "Should have less SY after round trip due to price impact");
        
        // PT should be the same as before (minus a tiny rounding error perhaps)
        assertApproxEqAbs(finalPTBalance, initialPTBalance, 10, "Should have approximately same PT after round trip");
        
        // The lost SY represents the implicit fee due to price impact
        uint256 implicitFee = initialSYBalance - finalSYBalance;
        console.log("Implicit fee from price impact:", implicitFee);
        
        // The fee should be non-zero but relatively small compared to swap size
        assertTrue(implicitFee > 0, "Should pay some fee due to price impact");
        assertTrue(implicitFee < syToSwap / 10, "Fee should be less than 10% of swap amount");
    }
    
    // Test the getQuotePTtoSY and getRequiredPTforSY functions with various amounts
    function test_PT_to_SY_quote_functions() public {
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        // Test exact input quotes (getQuotePTtoSY)
        uint256[] memory ptAmounts = new uint256[](4);
        ptAmounts[0] = 0.1 ether;
        ptAmounts[1] = 1 ether;
        ptAmounts[2] = 5 ether;
        ptAmounts[3] = 10 ether;
        
        for (uint i = 0; i < ptAmounts.length; i++) {
            uint256 expectedSYOutput = hook.getQuotePTtoSY(ptAmounts[i]);
            console.log("PT input:", ptAmounts[i] / 1 ether);
            console.log("Expected SY output:", expectedSYOutput / 1 ether);
            
            // Verify with actual swap
            uint256 prevSYBalance = key.currency0.balanceOf(address(this));
            
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(ptAmounts[i]),
                    sqrtPriceLimitX96: MAX_PRICE_LIMIT
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            );
            
            uint256 actualSYOutput = key.currency0.balanceOf(address(this)) - prevSYBalance;
            console.log("Actual SY output:", actualSYOutput / 1 ether);
            
            assertApproxEqRel(actualSYOutput, expectedSYOutput, 0.01e18, 
                "Actual SY output should match expected output");
                
            // Replenish liquidity for the next test to keep rates stable
            if (i < ptAmounts.length - 1) {
                hook.addLiquidity(
                    ZooCustomAccounting.AddLiquidityParams(
                        actualSYOutput, ptAmounts[i], 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
                    )
                );
            }
        }
        
        // Test exact output quotes (getRequiredPTforSY)
        uint256[] memory syAmounts = new uint256[](4);
        syAmounts[0] = 0.1 ether;
        syAmounts[1] = 1 ether;
        syAmounts[2] = 5 ether;
        syAmounts[3] = 10 ether;
        
        // Add fresh liquidity to reset the pool state
        hook.addLiquidity(
            ZooCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        
        for (uint i = 0; i < syAmounts.length; i++) {
            uint256 expectedPTInput = hook.getRequiredPTforSY(syAmounts[i]);
            console.log("SY output desired:", syAmounts[i] / 1 ether);
            console.log("Expected PT input:", expectedPTInput / 1 ether);
            
            // Verify with actual swap
            uint256 prevSYBalance = key.currency0.balanceOf(address(this));
            uint256 prevPTBalance = key.currency1.balanceOf(address(this));
            
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: int256(syAmounts[i]),
                    sqrtPriceLimitX96: MAX_PRICE_LIMIT
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            );
            
            uint256 actualSYReceived = key.currency0.balanceOf(address(this)) - prevSYBalance;
            uint256 actualPTSpent = prevPTBalance - key.currency1.balanceOf(address(this));
            console.log("Actual SY received:", actualSYReceived / 1 ether);
            console.log("Actual PT spent:", actualPTSpent / 1 ether);
            
            assertEq(actualSYReceived, syAmounts[i], "Should receive exactly the requested SY amount");
            assertApproxEqRel(actualPTSpent, expectedPTInput, 0.01e18, 
                "Actual PT spent should match expected input");
                
            // Replenish liquidity for the next test to keep rates stable
            if (i < syAmounts.length - 1) {
                hook.addLiquidity(
                    ZooCustomAccounting.AddLiquidityParams(
                        syAmounts[i], actualPTSpent, 0, 0, address(this), MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
                    )
                );
            }
        }
    }
}
