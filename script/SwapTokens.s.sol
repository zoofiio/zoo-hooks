// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol"; // Added import for BalanceDelta
import {StandardYieldToken} from "src/tokens/StandardYieldToken.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldSwapHook} from "src/YieldSwapHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapHelper} from "./SwapHelper.sol";

/**
 * @title SwapTokens
 * @notice Script to swap tokens in both directions: SY to PT and PT to SY using the YieldSwapHook
 * @dev Run with: forge script script/SwapTokens.s.sol --rpc-url <network> --broadcast
 */
contract SwapTokens is Script {
    using stdJson for string;
    using CurrencyLibrary for Currency;
    
    // Swap amount - 10 tokens for each swap
    uint256 public constant SWAP_AMOUNT = 10 ether;
    
    // Pool parameters
    uint24 public constant FEE = 3000; // 0.3% fee tier
    int24 public constant TICK_SPACING = 60; // Standard tick spacing for 0.3% fee tier
    uint256 public constant MAX_DEADLINE = type(uint256).max;
    
    // Contract addresses loaded from deployment file
    address protocolAddress;
    address syTokenAddress;
    address ptTokenAddress;
    address hookAddress;
    string network;
    
    StandardYieldToken public syToken;
    PrincipalToken public ptToken;
    YieldSwapHook public hook;
    SwapHelper public swapHelper;
    
    // Network-specific deployment file path
    function getDeploymentPath(string memory _network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", _network, ".json"));
    }
    
    function loadDeployment() internal {
        // Get network from env or use sepolia as default
        network = vm.envOr("NETWORK", string("sepolia"));
        string memory deploymentPath = getDeploymentPath(network);
        
        // Try to read deployment file
        string memory deploymentJson;
        try vm.readFile(deploymentPath) returns (string memory json) {
            deploymentJson = json;
        } catch {
            revert(string(abi.encodePacked("Failed to read deployment file for network: ", network)));
        }
        
        // Extract contract addresses
        bytes memory protocolRaw = stdJson.parseRaw(deploymentJson, ".Protocol.address");
        bytes memory syTokenRaw = stdJson.parseRaw(deploymentJson, ".StandardYieldToken.address");
        bytes memory ptTokenRaw = stdJson.parseRaw(deploymentJson, ".PrincipalToken.address");
        bytes memory hookRaw = stdJson.parseRaw(deploymentJson, ".YieldSwapHook.address");
        
        protocolAddress = abi.decode(protocolRaw, (address));
        syTokenAddress = abi.decode(syTokenRaw, (address));
        ptTokenAddress = abi.decode(ptTokenRaw, (address));
        hookAddress = abi.decode(hookRaw, (address));
        
        console.log("Loaded deployment from network:", network);
        console.log("Protocol:", protocolAddress);
        console.log("SY Token:", syTokenAddress);
        console.log("PT Token:", ptTokenAddress);
        console.log("YieldSwapHook:", hookAddress);
    }
    
    function run() public {
        // Load deployment information
        loadDeployment();
        
        // Load private key from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Initialize contracts with deployed addresses
        syToken = StandardYieldToken(syTokenAddress);
        ptToken = PrincipalToken(ptTokenAddress);
        hook = YieldSwapHook(hookAddress);
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Check token balances first
        uint256 syBalanceBefore = syToken.balanceOf(deployer);
        uint256 ptBalanceBefore = ptToken.balanceOf(deployer);
        
        console.log("\nInitial balances:");
        console.log("SY Token:", syBalanceBefore / 1 ether, "ether");
        console.log("PT Token:", ptBalanceBefore / 1 ether, "ether");
        
        // Make sure we have enough tokens for both swaps
        require(syBalanceBefore >= SWAP_AMOUNT, "Not enough SY tokens for swap");
        
        // 2. Approve tokens for YieldSwapHook (if not already approved)
        if (syToken.allowance(deployer, hookAddress) < SWAP_AMOUNT) {
            syToken.approve(hookAddress, type(uint256).max);
            console.log("Approved SY tokens for YieldSwapHook");
        }
        
        if (ptToken.allowance(deployer, hookAddress) < SWAP_AMOUNT) {
            ptToken.approve(hookAddress, type(uint256).max);
            console.log("Approved PT tokens for YieldSwapHook");
        }
        
        // 3. Create pool key with properly ordered currencies
        // Sort tokens by address so the smaller one is currency0
        (address token0, address token1) = address(syToken) < address(ptToken) 
            ? (address(syToken), address(ptToken)) 
            : (address(ptToken), address(syToken));
            
        console.log("\nPool tokens:");
        console.log("token0 (smaller address):", token0);
        console.log("token1 (larger address):", token1);
        
        // Determine token order
        bool syIsToken0 = (token0 == address(syToken));
        
        // Create pool key with properly ordered currencies
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        
        // 4. Check pool reserves before swaps
        (uint256 reserve0Before, uint256 reserve1Before) = hook.getReserves(poolKey);
        console.log("\nPool reserves before swaps:");
        console.log("Reserve0:", reserve0Before / 1 ether, "ether");
        console.log("Reserve1:", reserve1Before / 1 ether, "ether");
        
        // Get pool manager instance from hook
        IPoolManager poolManager = hook.poolManager();
        
        // Deploy our swap helper
        swapHelper = new SwapHelper(poolManager);
        console.log("\nDeployed SwapHelper at:", address(swapHelper));
        
        // Approve tokens to SwapHelper
        syToken.approve(address(swapHelper), SWAP_AMOUNT);
        ptToken.approve(address(swapHelper), SWAP_AMOUNT);
        console.log("Approved tokens for SwapHelper");
        
        // =============== FIRST SWAP: SY to PT ===============
        console.log("\n======= SWAP 1: SY to PT =======");
        console.log("Swapping", SWAP_AMOUNT / 1 ether, "SY tokens for PT tokens...");
        
        // Set zeroForOne based on token order for SY to PT swap
        bool zeroForOneFirstSwap = syIsToken0; // If SY is token0, we're swapping 0->1
        
        // Prepare swap params for SY to PT
        IPoolManager.SwapParams memory paramsFirstSwap = IPoolManager.SwapParams({
            zeroForOne: zeroForOneFirstSwap, // This will be true if SY is token0, false if SY is token1
            amountSpecified: -int256(SWAP_AMOUNT), // Negative for exact input swap
            sqrtPriceLimitX96: zeroForOneFirstSwap ? 4295128740 : 1461446703485210103287273052203988822378723970341 // Min/max acceptable price limits
        });
        
        uint256 ptReceived;
        try swapHelper.swap(poolKey, paramsFirstSwap, deployer) returns (BalanceDelta delta) {
            int256 amount0Delta = delta.amount0();
            int256 amount1Delta = delta.amount1();
            
            // Calculate amount received based on which token was received
            ptReceived = uint256(zeroForOneFirstSwap ? amount1Delta : amount0Delta);
            
            console.log("SY to PT swap executed successfully");
            console.log("Amount0 delta:", amount0Delta);
            console.log("Amount1 delta:", amount1Delta);
            console.log("PT tokens received:", ptReceived / 1e18, "ether");
        } catch Error(string memory reason) {
            console.log("SY to PT swap failed with reason:", reason);
            vm.stopBroadcast();
            return;
        } catch {
            console.log("SY to PT swap failed with unknown error");
            vm.stopBroadcast();
            return;
        }
        
        // Check balances after first swap
        uint256 syBalanceAfterFirstSwap = syToken.balanceOf(deployer);
        uint256 ptBalanceAfterFirstSwap = ptToken.balanceOf(deployer);
        
        console.log("\nSY to PT swap completed:");
        console.log("SY spent:", (syBalanceBefore - syBalanceAfterFirstSwap) / 1 ether, "ether");
        console.log("PT received:", (ptBalanceAfterFirstSwap - ptBalanceBefore) / 1 ether, "ether");
        console.log("Swap rate:", ((ptBalanceAfterFirstSwap - ptBalanceBefore) * 1e18) / SWAP_AMOUNT);
        
        // Check pool reserves after first swap
        (uint256 reserve0AfterFirstSwap, uint256 reserve1AfterFirstSwap) = hook.getReserves(poolKey);
        console.log("\nPool reserves after SY to PT swap:");
        console.log("Reserve0:", reserve0AfterFirstSwap / 1 ether, "ether");
        console.log("Reserve1:", reserve1AfterFirstSwap / 1 ether, "ether");
        
        // =============== SECOND SWAP: PT to SY ===============
        console.log("\n======= SWAP 2: PT to SY =======");
        console.log("Swapping", SWAP_AMOUNT / 1 ether, "PT tokens for SY tokens...");
        
        // For PT to SY swap, the direction is opposite of SY to PT swap
        bool zeroForOneSecondSwap = !zeroForOneFirstSwap;
        
        // Prepare swap params for PT to SY swap
        IPoolManager.SwapParams memory paramsSecondSwap = IPoolManager.SwapParams({
            zeroForOne: zeroForOneSecondSwap, // This will be false if SY is token0, true if SY is token1
            amountSpecified: -int256(SWAP_AMOUNT), // Negative for exact input swap
            sqrtPriceLimitX96: zeroForOneSecondSwap ? 4295128740 : 1461446703485210103287273052203988822378723970341 // Min/max acceptable price limits
        });
        
        uint256 syReceived;
        try swapHelper.swap(poolKey, paramsSecondSwap, deployer) returns (BalanceDelta delta) {
            int256 amount0Delta = delta.amount0();
            int256 amount1Delta = delta.amount1();
            
            // Calculate amount received based on which token was received
            syReceived = uint256(zeroForOneSecondSwap ? amount1Delta : amount0Delta);
            
            console.log("PT to SY swap executed successfully");
            console.log("Amount0 delta:", amount0Delta);
            console.log("Amount1 delta:", amount1Delta);
            console.log("SY tokens received:", syReceived / 1e18, "ether");
        } catch Error(string memory reason) {
            console.log("PT to SY swap failed with reason:", reason);
            vm.stopBroadcast();
            return;
        } catch {
            console.log("PT to SY swap failed with unknown error");
            vm.stopBroadcast();
            return;
        }
        
        // Check final balances after both swaps
        uint256 syBalanceAfter = syToken.balanceOf(deployer);
        uint256 ptBalanceAfter = ptToken.balanceOf(deployer);
        
        console.log("\nPT to SY swap completed:");
        console.log("PT spent:", SWAP_AMOUNT / 1e18, "ether");
        console.log("SY received:", (syBalanceAfter - syBalanceAfterFirstSwap) / 1e18, "ether");
        console.log("Swap rate:", ((syBalanceAfter - syBalanceAfterFirstSwap) * 1e18) / SWAP_AMOUNT);
        
        // Check final pool reserves after both swaps
        (uint256 reserve0After, uint256 reserve1After) = hook.getReserves(poolKey);
        console.log("\nPool reserves after both swaps:");
        console.log("Reserve0:", reserve0After / 1e18, "ether");
        console.log("Reserve1:", reserve1After / 1e18, "ether");
        
        // Print summary of both swaps
        console.log("\n======= SWAPS SUMMARY =======");
        console.log("Initial SY balance:", syBalanceBefore / 1e18, "ether");
        console.log("Final SY balance:", syBalanceAfter / 1e18, "ether");
        // console.log("Net SY change:", (syBalanceAfter - syBalanceBefore) / 1e18, "ether");
        
        console.log("Initial PT balance:", ptBalanceBefore / 1e18, "ether");
        console.log("Final PT balance:", ptBalanceAfter / 1e18, "ether");
        // console.log("Net PT change:", (ptBalanceAfter - ptBalanceBefore) / 1e18, "ether");
        
        vm.stopBroadcast();
    }
}
