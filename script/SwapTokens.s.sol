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
 * @notice Script to swap SY tokens for PT tokens using the YieldSwapHook
 * @dev Run with: forge script script/SwapTokens.s.sol --rpc-url arbitrum --broadcast
 */
contract SwapTokens is Script {
    using stdJson for string;
    using CurrencyLibrary for Currency;
    
    // Swap amount - 100 SY tokens
    uint256 public constant SWAP_AMOUNT = 100 ether;
    
    // Pool parameters (must match those used in AddInitialLiquidity)
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
    
    // Network-specific deployment file path
    function getDeploymentPath(string memory _network) internal pure returns (string memory) {
        return string(abi.encodePacked("./deployments/", _network, ".json"));
    }
    
    function loadDeployment() internal {
        // Always use arbitrum network for this script
        network = "arbitrum";
        string memory deploymentPath = getDeploymentPath(network);
        
        // Try to read deployment file
        string memory deploymentJson;
        try vm.readFile(deploymentPath) returns (string memory json) {
            deploymentJson = json;
        } catch {
            revert("Failed to read deployment file. Make sure contracts are deployed on Arbitrum first.");
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
        
        console.log("Loaded deployment from Arbitrum");
        console.log("Protocol:", protocolAddress);
        console.log("SY Token:", syTokenAddress);
        console.log("PT Token:", ptTokenAddress);
        console.log("YieldSwapHook:", hookAddress);
    }
    
    function run() public {
        // Load deployment information from Arbitrum
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
        
        // Make sure we have enough SY tokens
        require(syBalanceBefore >= SWAP_AMOUNT, "Not enough SY tokens for swap");
        
        // 2. Approve tokens for YieldSwapHook (if not already approved)
        if (syToken.allowance(deployer, hookAddress) < SWAP_AMOUNT) {
            syToken.approve(hookAddress, type(uint256).max);
            console.log("Approved SY tokens for YieldSwapHook");
        }
        
        // 3. Create pool key with properly ordered currencies
        // Sort tokens by address so the smaller one is currency0
        (address token0, address token1) = address(syToken) < address(ptToken) 
            ? (address(syToken), address(ptToken)) 
            : (address(ptToken), address(syToken));
            
        console.log("\nPool tokens:");
        console.log("token0 (smaller address):", token0);
        console.log("token1 (larger address):", token1);
        
        // Determine if SY is token0 or token1 - affects how we call swap
        bool syIsToken0 = (token0 == address(syToken));
        
        // Create pool key with properly ordered currencies
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        
        // 4. Check pool reserves before swap
        (uint256 reserve0Before, uint256 reserve1Before) = hook.getReserves(poolKey);
        console.log("\nPool reserves before swap:");
        console.log("Reserve0:", reserve0Before / 1 ether, "ether");
        console.log("Reserve1:", reserve1Before / 1 ether, "ether");
        
        // 5. Execute the swap via SwapHelper contract
        console.log("\nSwapping", SWAP_AMOUNT / 1 ether, "SY tokens for PT tokens...");
        
        // Get pool manager instance from hook
        IPoolManager poolManager = hook.poolManager();
        
        // Deploy our swap helper
        SwapHelper swapHelper = new SwapHelper(poolManager);
        console.log("Deployed SwapHelper at:", address(swapHelper));
        
        // Approve SY token to SwapHelper
        syToken.approve(address(swapHelper), SWAP_AMOUNT);
        console.log("Approved SY tokens for SwapHelper");
        
        // We need to specify if we're swapping from token0 to token1 or vice versa
        bool zeroForOne = syIsToken0; // If SY is token0, we're swapping 0->1
        
        // To fix the OnlySYToPTSwapsSupported error, we need to ensure we're always
        // swapping from SY to PT, regardless of which one is currency0 or currency1
        
        // In YieldSwapHook, if SY is currency1 and PT is currency0,
        // then we need to swap from currency1 to currency0 (zeroForOne = false)
        // Otherwise, if SY is currency0 and PT is currency1, 
        // then we need to swap from currency0 to currency1 (zeroForOne = true)
        
        // Prepare swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: syIsToken0, // This will be true if SY is token0, false if SY is token1
            amountSpecified: -int256(SWAP_AMOUNT), // Negative for exact input swap
            sqrtPriceLimitX96: syIsToken0 ? 4295128740 : 1461446703485210103287273052203988822378723970341 // Min/max acceptable price limits
        });
        
        try swapHelper.swap(poolKey, params, deployer) returns (BalanceDelta delta) {
            // Swaps return a BalanceDelta struct that contains amount0 and amount1
            int256 amount0Delta = delta.amount0();
            int256 amount1Delta = delta.amount1();
            
            // Calculate amount received based on which token was received
            uint256 amountOut = uint256(-1 * (zeroForOne ? amount1Delta : amount0Delta));
            console.log("Swap executed successfully");
            console.log("Amount0 delta:", amount0Delta);
            console.log("Amount1 delta:", amount1Delta);
            console.log("Tokens received:", amountOut / 1 ether, "ether");
        } catch Error(string memory reason) {
            console.log("Swap failed with reason:", reason);
            revert("Swap failed");
        } catch {
            console.log("Swap failed with unknown error");
            revert("Swap failed with unknown error");
        }
        
        // 6. Check balances after swap
        uint256 syBalanceAfter = syToken.balanceOf(deployer);
        uint256 ptBalanceAfter = ptToken.balanceOf(deployer);
        
        console.log("\nSwap completed:");
        console.log("SY spent:", (syBalanceBefore - syBalanceAfter) / 1 ether, "ether");
        console.log("PT received:", (ptBalanceAfter - ptBalanceBefore) / 1 ether, "ether");
        console.log("Swap rate:", ((ptBalanceAfter - ptBalanceBefore) * 1e18) / SWAP_AMOUNT);
        
        // 7. Check pool reserves after swap
        (uint256 reserve0After, uint256 reserve1After) = hook.getReserves(poolKey);
        console.log("\nPool reserves after swap:");
        console.log("Reserve0:", reserve0After / 1 ether, "ether");
        console.log("Reserve1:", reserve1After / 1 ether, "ether");
        
        vm.stopBroadcast();
    }
}
