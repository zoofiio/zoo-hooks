// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StandardYieldToken} from "src/tokens/StandardYieldToken.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldSwapHook} from "src/YieldSwapHook.sol";
import {ZooCustomAccounting} from "src/base/ZooCustomAccounting.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract AddInitialLiquidity is Script {
    using stdJson for string;
    using CurrencyLibrary for Currency;
    
    // Constants for liquidity provision
    uint256 public constant MINT_AMOUNT = 1_000_000 ether;
    uint256 public constant SY_LIQUIDITY = 100_000 ether;
    uint256 public constant PT_LIQUIDITY = 90_000 ether;
    
    // Pool parameters
    int24 public constant MIN_TICK = -887220;
    int24 public constant MAX_TICK = 887220;
    uint256 public constant MAX_DEADLINE = type(uint256).max;
    uint24 public constant FEE = 3000; // 0.3% fee tier
    int24 public constant TICK_SPACING = 60; // Standard tick spacing for 0.3% fee tier
    
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
        // Get network from env or use sepolia as default
        network = vm.envOr("NETWORK", string("sepolia"));
        string memory deploymentPath = getDeploymentPath(network);
        
        // Try to read deployment file for the specified network
        string memory deploymentJson;
        try vm.readFile(deploymentPath) returns (string memory json) {
            deploymentJson = json;
        } catch {
            // Fall back to latest.json if network-specific file doesn't exist
            deploymentJson = vm.readFile("./deployments/latest.json");
        }
        
        // Extract contract addresses using proper stdJson parsing
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
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Mint tokens to owner (deployer)
        syToken.mint(deployer, MINT_AMOUNT);
        ptToken.mint(deployer, MINT_AMOUNT);
        
        console.log("\nMinted tokens to deployer:");
        console.log("SY Token:", MINT_AMOUNT / 1 ether, "ether");
        console.log("PT Token:", MINT_AMOUNT / 1 ether, "ether");
        
        // 2. Approve tokens for YieldSwapHook
        syToken.approve(hookAddress, type(uint256).max);
        ptToken.approve(hookAddress, type(uint256).max);
        console.log("\nApproved tokens for YieldSwapHook");
        
        // 3. First create and initialize the pool - Order currencies properly
        // Sort tokens by address so the smaller one is currency0
        (address token0, address token1) = address(syToken) < address(ptToken) 
            ? (address(syToken), address(ptToken)) 
            : (address(ptToken), address(syToken));
            
        console.log("\nSorted token addresses:");
        console.log("token0 (smaller address):", token0);
        console.log("token1 (larger address):", token1);
        
        // Create pool key with properly ordered currencies
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        
        // Get pool manager address from the hook
        IPoolManager poolManager = hook.poolManager();
        
        // Calculate the initial price - using 1:1 ratio
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1.0 as Q96.64
        
        console.log("\nInitializing pool with initial price:", uint256(sqrtPriceX96));
        console.log("Pool Manager address:", address(poolManager));
        
        // Initialize the pool using the pool manager
        try poolManager.initialize(poolKey, sqrtPriceX96) {
            console.log("Pool initialized successfully");
        } catch Error(string memory reason) {
            console.log("Pool initialization failed:", reason);
        } catch {
            console.log("Pool initialization failed with unknown error");
        }
        
        // 4. Now add initial liquidity with the same poolKey
        // Check which token is which to determine amount0 and amount1
        uint256 amount0Desired;
        uint256 amount1Desired;
        
        if (token0 == address(syToken)) {
            amount0Desired = SY_LIQUIDITY;
            amount1Desired = PT_LIQUIDITY;
        } else {
            amount0Desired = PT_LIQUIDITY;
            amount1Desired = SY_LIQUIDITY;
        }
        
        ZooCustomAccounting.AddLiquidityParams memory params = ZooCustomAccounting.AddLiquidityParams({
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            to: deployer,
            deadline: MAX_DEADLINE,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32(0)
        });
        
        // Add liquidity
        hook.addLiquidity(params);
        
        // 5. Log results
        console.log("\nLiquidity added successfully:");
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Amount0:", amount0Desired / 1 ether, "ether");
        console.log("Amount1:", amount1Desired / 1 ether, "ether");
        console.log("LP tokens received:", hook.balanceOf(deployer) / 1 ether, "ether");
        
        // 6. Verify reserves
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(poolKey);
        
        console.log("\nVerifying pool reserves:");
        console.log("Reserve0:", reserve0 / 1 ether, "ether");
        console.log("Reserve1:", reserve1 / 1 ether, "ether");
        
        vm.stopBroadcast();
    }
}
