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

# Network selection
NETWORK=sepolia

# Pool Manager addresses
POOL_MANAGER_SEPOLIA=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
POOL_MANAGER_MAINNET=0x000000000004444c5dc75cB358380D2e3dE08A90

# Etherscan API keys (for contract verification)
ETHERSCAN_API_KEY=your_etherscan_api_key
BASESCAN_API_KEY=your_basescan_api_key
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

# Deploy contracts to the specified network
forge script script/DeployContracts.s.sol --rpc-url sepolia --broadcast --verify
```

## Add Initial Liquidity

After deploying the contracts, you can use the following command to add initial liquidity:

```bash
# Load environment variables from .env
source .env

# Add initial liquidity to YieldSwapHook
forge script script/AddInitialLiquidity.s.sol --rpc-url sepolia --broadcast
```

This script will:
1. Load deployed contract addresses from the deployments directory
2. Mint SY and PT tokens
3. Approve YieldSwapHook contract to use these tokens
4. Add initial liquidity to the Uniswap V4 pool
5. Verify reserves in the pool

## Verify Contracts

After deployment, get contract verification commands:

```bash
source .env
forge script script/Verify.s.sol --rpc-url sepolia
```

## Format Deployment JSON Files

If you need to format deployment JSON files, run:

```bash
forge script script/FormatJson.s.sol
```

## Contract Addresses

Contract addresses are stored in JSON files in the `deployments` directory:
- Network-specific files (e.g., `deployments/sepolia.json`)
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
