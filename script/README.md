# Deployment Scripts

This directory contains scripts for deploying and managing YieldSwapHook contracts.

## Prerequisites

1. Create a `.env` file in the project root by copying from the example:

```bash
cp .env.example .env
```

2. Edit `.env` file to add your private key and RPC URLs:

```bash
# Update these values in your .env file
PRIVATE_KEY=your_private_key_here
ETHERSCAN_API_KEY=your_etherscan_api_key
BASESCAN_API_KEY=your_basescan_api_key
```

3. Make sure you have the `deployments` directory:

```bash
mkdir -p deployments
```

## Setup

Before deploying, run the initialization script to ensure the deployments directory exists:

```bash
forge script script/InitDeployments.s.sol --rpc-url sepolia -vvvv
```

## Deployment

To deploy contracts:

```bash
forge script script/DeployContracts.s.sol --rpc-url sepolia --broadcast --verify
```

## Verify Contracts

After deployment, get verification commands:

```bash
forge script script/Verify.s.sol --rpc-url sepolia -vvv
```

## Contract Addresses

Contract addresses are stored in JSON files in the `deployments` directory:
- Network-specific files (e.g., `deployments/sepolia.json`)
- Latest deployment: `deployments/latest.json`

The JSON format is:
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
