# ZooFi Deployment Scripts

This directory contains scripts for deploying and initializing YieldSwapHook contracts.

## Environment Setup

Before deployment, make sure you've created a `.env` file with the necessary variables:

```
# Private key
PRIVATE_KEY=your_private_key_here

# RPC endpoints
RPC_URL_SEPOLIA=https://sepolia.infura.io/v3/your_infura_key
RPC_URL_MAINNET=https://mainnet.infura.io/v3/your_infura_key
RPC_URL_BASE=https://base.llamarpc.com
RPC_URL_ARBITRUM=https://arb1.arbitrum.io/rpc

# Network selection
NETWORK=sepolia  # Options: sepolia, mainnet, base, arbitrum

# Pool Manager addresses
POOL_MANAGER_SEPOLIA=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
POOL_MANAGER_MAINNET=0x000000000004444c5dc75cB358380D2e3dE08A90
POOL_MANAGER_ARBITRUM=0x360e68faccca8ca495c1b759fd9eee466db9fb32

# Etherscan API keys (for contract verification)
ETHERSCAN_API_KEY=your_etherscan_api_key
BASESCAN_API_KEY=your_basescan_api_key
ARBISCAN_API_KEY=your_arbiscan_api_key
```

Also ensure the deployments directory exists:

```bash
mkdir -p deployments
```

## Deploy Contracts

Run the following command to deploy all relevant contracts (Protocol, StandardYieldToken, PrincipalToken, YieldSwapHook):

```bash
# Load environment variables from .env
source .env

# Deploy to specific network (e.g., Arbitrum)
export NETWORK=arbitrum
forge script script/DeployContracts.s.sol --rpc-url arbitrum --broadcast --verify
```

## Add Initial Liquidity and Swap

After deploying the contracts, you can use the following command to add initial liquidity:

```bash
# Load environment variables from .env
source .env

# Add initial liquidity on Arbitrum
export NETWORK=arbitrum
forge script script/AddInitialLiquidity.s.sol --rpc-url arbitrum --broadcast

# Swap
forge script script/SwapTokens.s.sol --rpc-url arbitrum --broadcast
```

This script will:
1. Load deployed contract addresses from the deployments directory
2. Mint SY and PT tokens
3. Approve YieldSwapHook contract to use these tokens
4. Initialize a pool if needed
5. Add initial liquidity to the Uniswap V4 pool
6. Verify reserves in the pool

## Verify Contracts

After deployment, get contract verification commands:

```bash
source .env
export NETWORK=arbitrum
forge script script/Verify.s.sol --rpc-url arbitrum

# e.g.
# forge verify-contract  --chain 42161 0x09E73495F519e3c58172bE06D54E92905210C43E src/tokens/StandardYieldToken.sol:StandardYieldToken --constructor-args $(cast abi-encode "constructor(address)" 0xD4EA290223Ae45EBe87E36f2500270b1CA404Ef7) --etherscan-api-key $ETHERSCAN_API_KEY_ARBITRUM
```

## Format Deployment JSON Files

If you need to format deployment JSON files, run:

```bash
forge script script/FormatJson.s.sol
```

## Troubleshooting

### Uniswap Frontend "No Routes Available" Issue

When using the Uniswap frontend to swap SY -> PT tokens, you may encounter a "No routes available" error despite successfully executing swaps via the SwapTokens.s.sol script. This can occur for several reasons:

1. **Custom Hook Recognition**: YieldSwapHook is a custom hook that implements specialized swap logic which the standard Uniswap router may not recognize. The script works because it directly interacts with the hook and pool manager.

2. **Indexing Delay**: The Uniswap frontend relies on subgraphs and indexers to discover pools and routes. New pools may not be immediately indexed and therefore not visible to the frontend.

3. **Limited V4 Frontend Support**: Uniswap's interface may have limited support for custom V4 hooks and pools that utilize non-standard swap logic.

4. **Pool Visibility**: Some hooks may implement permissions or custom logic that makes them incompatible with standard routing algorithms.

#### Workarounds

To interact with your pools despite this issue:

1. **Direct Script Interaction**: Continue using the provided Forge scripts for reliable swaps.

2. **Custom Frontend**: Build a custom frontend that understands your specific hook logic.

3. **Manual Pool Contract Interaction**: Use block explorers like Arbiscan to interact directly with your pool contracts.

4. **Wait for Indexing**: Sometimes waiting 24-48 hours allows indexers to discover and register new pools.

5. **Verify Pool Parameters**: Ensure your pool parameters like fee tier and tick spacing match standard configurations that Uniswap's routers expect.

```bash
# Example of manual swap using script (reliable method)
forge script script/SwapTokens.s.sol --rpc-url arbitrum --broadcast
```

## Contract Addresses

Contract addresses are stored in JSON files in the `deployments` directory:
- Network-specific files (e.g., `deployments/arbitrum.json`)
- Latest deployment: `deployments/latest.json`

JSON format example:
```json
{
  "Protocol": {
    "address": "0x3f3e44fc9842F8bF64D8277D2559130191924B96",
    "contract": "src/Protocol.sol:Protocol",
    "args": []
  },
  "StandardYieldToken": {
    "address": "0x8ce947b41F404e9b52191b35c12634FC1DA630C3",
    "contract": "src/tokens/StandardYieldToken.sol:StandardYieldToken", 
    "args": [
      "0x3f3e44fc9842F8bF64D8277D2559130191924B96"
    ]
  }
}
```
