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
    uint256 public constant SY_LIQUIDITY = 60_000 ether;
    uint256 public constant PT_LIQUIDITY = 40_000 ether;
    
    // Pool parameters
    int24 public constant MIN_TICK = -887220;
    int24 public constant MAX_TICK = 887220;
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
        
        // 3. Add initial liquidity
        // Create AddLiquidityParams
        ZooCustomAccounting.AddLiquidityParams memory params = ZooCustomAccounting.AddLiquidityParams({
            amount0Desired: SY_LIQUIDITY,
            amount1Desired: PT_LIQUIDITY,
            amount0Min: 0,  // No slippage protection for initial liquidity
            amount1Min: 0,  // No slippage protection for initial liquidity
            to: deployer,   // Send LP tokens to deployer
            deadline: MAX_DEADLINE,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32(0)
        });
        
        // Add liquidity
        hook.addLiquidity(params);
        
        // 4. Log results
        console.log("\nLiquidity added successfully:");
        console.log("SY added:", SY_LIQUIDITY / 1 ether, "ether");
        console.log("PT added:", PT_LIQUIDITY / 1 ether, "ether");
        console.log("LP tokens received:", hook.balanceOf(deployer) / 1 ether, "ether");
        
        // 5. Verify reserves - Fix poolKey() usage issue
        (uint256 reserveSY, uint256 reservePT) = hook.getReserves(PoolKey({
            currency0: Currency.wrap(address(syToken)),
            currency1: Currency.wrap(address(ptToken)), 
            fee: 0, // Use appropriate fee value
            tickSpacing: 60, // Use appropriate tick spacing
            hooks: IHooks(address(hook)) // Cast hook address to IHooks
        }));
        
        console.log("\nVerifying pool reserves:");
        console.log("SY reserves:", reserveSY / 1 ether, "ether");
        console.log("PT reserves:", reservePT / 1 ether, "ether");
        
        vm.stopBroadcast();
    }
}
