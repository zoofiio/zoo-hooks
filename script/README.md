# Deployment Scripts

These scripts help deploy and initialize the ZooFi yield hooks contracts.

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

## Deployment Steps

### 1. Deploy Contracts

This will deploy Protocol, StandardYieldToken, PrincipalToken, and YieldSwapHook:

```bash
source .env
forge script script/DeployContracts.s.sol --rpc-url sepolia --broadcast --verify
```

The script will automatically load the PRIVATE_KEY and other variables from your .env file. It will save the deployment information to the `./deployments/` directory.

### 2. Add Initial Liquidity

This script mints SY and PT tokens to the deployer and adds initial liquidity to the YieldSwapHook:

```bash
source .env
forge script script/AddInitialLiquidity.s.sol --rpc-url $RPC_URL_SEPOLIA --broadcast
```

The script will load the deployment addresses from `./deployments/latest.json`.

## Verifying Contracts

After deployment, you need to verify the contracts on the blockchain explorer. Foundry provides two methods for verification:

### Method 1: Automatic Verification During Deployment

Add the `--verify` flag to the deployment command:

```bash
source .env
forge script script/DeployContracts.s.sol --rpc-url $RPC_URL_SEPOLIA --broadcast --verify
```

This requires you to have set the appropriate API key in your `.env` file:
- `ETHERSCAN_API_KEY` for Ethereum networks (mainnet, sepolia, etc.)
- `BASESCAN_API_KEY` for Base networks

### Method 2: Manual Verification

You can also verify contracts manually after deployment:

```bash
# Verify Protocol contract
forge verify-contract \
  --chain-id <CHAIN_ID> \
  --watch \
  --constructor-args $(cast abi-encode "constructor()") \
  <PROTOCOL_ADDRESS> \
  src/Protocol.sol:Protocol
  
# Verify SY Token contract
forge verify-contract \
  --chain-id <CHAIN_ID> \
  --watch \
  --constructor-args $(cast abi-encode "constructor(address)" <PROTOCOL_ADDRESS>) \
  <SY_TOKEN_ADDRESS> \
  src/tokens/StandardYieldToken.sol:StandardYieldToken

# Verify PT Token contract
forge verify-contract \
  --chain-id <CHAIN_ID> \
  --watch \
  --constructor-args $(cast abi-encode "constructor(address)" <PROTOCOL_ADDRESS>) \
  <PT_TOKEN_ADDRESS> \
  src/tokens/PrincipalToken.sol:PrincipalToken

# Verify YieldSwapHook contract
forge verify-contract \
  --chain-id <CHAIN_ID> \
  --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256,uint256)" <PROTOCOL_ADDRESS> <POOL_MANAGER_ADDRESS> <EPOCH_START> <EPOCH_DURATION>) \
  <HOOK_ADDRESS> \
  src/YieldSwapHook.sol:YieldSwapHook
```

Replace `<CHAIN_ID>`, `<PROTOCOL_ADDRESS>`, and other placeholders with your actual values from the deployment output. You can find chain IDs here:
- Ethereum Mainnet: 1
- Sepolia: 11155111
- Base: 8453
- Base Goerli: 84531

### Verification Helper Script

You can use the following helper command to generate the verification commands with the correct parameters from your deployment:

```bash
# Read deployment details and output verification commands
forge script script/Verify.s.sol
```

## Configuring Network

To deploy to a different network, update the `NETWORK` variable in your `.env` file:

```
NETWORK=base  # or sepolia, mainnet, etc.
```

Then run the deployment commands using the corresponding RPC URL:

```bash
source .env
forge script script/DeployContracts.s.sol --rpc-url $RPC_URL_BASE --broadcast --verify
```
