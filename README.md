# StackSave - DeFi Savings Goals with Octant Donations

A decentralized savings platform that helps users achieve financial goals while supporting public goods through yield donations to Octant.

**Built for:** Octant DeFi Hackathon 2025
**Network:** Tenderly Mainnet Fork (Testnet)

---

## 🎯 Overview

StackSave allows users to:
- Create personalized savings goals (vacations, emergency funds, etc.)
- Earn yield on deposits through Morpho Blue integration
- Donate a percentage of their yield to public goods via Octant
- Choose between "Lite" (stablecoins) and "Pro" (volatile assets) modes

---

## 📍 Deployed Contracts

**Network:** Tenderly Fork (Chain ID: 8)
**Fork Dashboard:** https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff/transactions

| Contract | Address | Purpose |
|----------|---------|---------|
| **StackSaveOctant** | `0x8672C6b92d4C66A82F85CD724C08c8593a79d6a3` | Main savings contract |
| **OctantYieldRouter** | `0x4C796ea1840927Fe851a9dA30A679268b33e841d` | Routes yield donations to Octant |
| **USDC Vault (Lite)** | `0x7C233fBD91BE4d11ba233f5372dF3045C14eAC30` | USDC savings vault |
| **DAI Vault (Lite)** | `0xeF85F786c9Cc624a6A02D9710DDD2AC1f42391BD` | DAI savings vault |
| **WETH Vault (Pro)** | `0x6a67A0e395774d8C95CAF7c479292F52D2A80220` | WETH savings vault |
| **TokenFaucet** | `0xbCA64F501Ab77518250ba17d7B9101eD1644E998` | Test token distributor |

---

## ✨ Features

### 🎯 Savings Goals
- Create named goals with target amounts and durations
- Track progress with real-time balance updates
- Flexible donation percentages (0-100% of yield)

### 💰 Yield Generation
- Integrated with **Morpho Blue** lending protocol
- Earn passive yield on deposits
- Auto-compounding through vault strategies

### 🌍 Public Goods Support
- Donate yield to Octant PaymentSplitter
- Support quadratic funding for public goods
- Choose your own donation percentage

### 🔒 Two Modes
- **Lite Mode**: For stablecoins (USDC, DAI) - Lower risk
- **Pro Mode**: For volatile assets (WETH) - Higher risk, higher rewards

---

## 🚀 Quick Start

### Prerequisites

```bash
# Install Foundry if you haven't
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 1. Clone & Setup

```bash
cd SmartContract
forge install
```

### 2. Configure Environment

Create `.env` file:
```bash
PRIVATE_KEY=your_private_key_here
```

### 3. Interact with Contracts

**RPC URL:**
```bash
export RPC=https://virtual.mainnet.eu.rpc.tenderly.co/82c86106-662e-4d7f-a974-c311987358ff
```

---

## 📖 Usage Examples

### Create a Savings Goal

```bash
cast send 0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  "createGoal(string,address,uint8,uint256,uint256,uint256)" \
  "Emergency Fund" \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  0 \
  1000000000 \
  7776000 \
  5000 \
  --rpc-url $RPC \
  --private-key $PRIVATE_KEY
```

**Parameters:**
- **Name**: "Emergency Fund"
- **Currency**: USDC address
- **Mode**: 0 (Lite) or 1 (Pro)
- **Target**: 1000 USDC (with 6 decimals = 1000000000)
- **Duration**: 90 days (7776000 seconds)
- **Donation**: 50% (5000 basis points, where 10000 = 100%)

### Deposit to Goal

```bash
# 1. Approve USDC
cast send 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  "approve(address,uint256)" \
  0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  1000000000000 \
  --rpc-url $RPC --private-key $PRIVATE_KEY

# 2. Deposit 500 USDC to goal ID 1
cast send 0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  "deposit(uint256,uint256)" \
  1 \
  500000000 \
  --rpc-url $RPC --private-key $PRIVATE_KEY
```

### Check Goal Progress

```bash
cast call 0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  "getGoalDetails(uint256)" \
  1 \
  --rpc-url $RPC
```

### Withdraw Funds

```bash
# Completed goal (no penalty)
cast send 0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  "withdrawCompleted(uint256)" \
  1 \
  --rpc-url $RPC --private-key $PRIVATE_KEY

# Early withdrawal (2% penalty)
cast send 0xa9EDF625508bE4AcE93d3013B0cC4A5c3BD69F1a \
  "withdrawEarly(uint256)" \
  1 \
  --rpc-url $RPC --private-key $PRIVATE_KEY
```

---

## 🏗️ Architecture

```
User
 │
 ├─> StackSaveOctant (Main Contract)
 │    ├─> Create Goals
 │    ├─> Manage Deposits
 │    └─> Handle Withdrawals
 │
 ├─> MorphoVaultAdapter (ERC4626 Vaults)
 │    ├─> USDC Vault (Lite Mode)
 │    ├─> DAI Vault (Lite Mode)
 │    └─> WETH Vault (Pro Mode)
 │         │
 │         └─> Morpho Blue (Yield Generation)
 │
 └─> OctantYieldRouter
      └─> Octant PaymentSplitter (Public Goods Funding)
```

---

## 📊 Supported Assets

| Asset | Address | Mode | Decimals | Faucet Amount |
|-------|---------|------|----------|---------------|
| **USDC** | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Lite | 6 | 100 |
| **DAI** | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | Lite | 18 | 500 |
| **WETH** | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | Pro | 18 | 0.1 |

---

## 🧪 Testing

### Run All Tests

```bash
forge test
```

### Test Specific Suite

```bash
# Integration tests
forge test --match-contract StackSaveIntegrationTest

# Unit tests
forge test --match-contract OctantYieldRouterTest
```

### Test Coverage

```bash
forge coverage
```

**Current Results:** 51/53 tests passing (96% pass rate)

---

## 🔧 Development

### Compile Contracts

```bash
forge build
```

### Deploy to Fork

```bash
forge script script/Deploy.s.sol:DeployStackSave \
  --rpc-url tenderly_fork \
  --broadcast \
  -vvvv
```

### Local Development

```bash
# Start local node
anvil

# Deploy locally
forge script script/Deploy.s.sol:DeployStackSave \
  --rpc-url http://localhost:8545 \
  --broadcast
```

---

## 📚 Contract Reference

### Goal Statuses

| Value | Status | Description |
|-------|--------|-------------|
| 0 | Active | Goal is in progress |
| 1 | Completed | Target amount reached |
| 2 | Abandoned | Early withdrawal taken |
| 3 | Withdrawn | Funds have been claimed |

### Modes

| Value | Mode | Description |
|-------|------|-------------|
| 0 | Lite | For stablecoins (lower risk) |
| 1 | Pro | For volatile assets (higher risk/reward) |

### Fees & Penalties

- **Early Withdrawal Penalty**: 2% of total assets
- **Penalty Distribution**:
  - 50% → Reward Pool
  - 50% → Treasury
- **No fees** for regular deposits/withdrawals

---

## 🎮 Integration Guide

### For Frontend Developers

```javascript
// Create a goal
await stackSaveContract.createGoal(
  "Vacation Fund",
  usdcAddress,
  0, // Lite mode
  ethers.parseUnits("5000", 6), // 5000 USDC
  90 * 24 * 60 * 60, // 90 days
  3000 // 30% donation
);

// Get user's goals
const goalIds = await stackSaveContract.getUserGoals(userAddress);

// Get goal details
const [goal, currentValue, yieldEarned] =
  await stackSaveContract.getGoalDetails(goalId);

// Check supported currencies
const currencies = await stackSaveContract.getSupportedCurrencies();
```

### ABI Files

Located in `out/` directory after compilation:
- `out/StackSaveOctant.sol/StackSaveOctant.json`
- `out/OctantYieldRouter.sol/OctantYieldRouter.json`
- `out/MorphoVaultAdapter.sol/MorphoVaultAdapter.json`

---

## 🌐 Resources

- **Tenderly Dashboard**: [View Transactions](https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff/transactions)
- **Morpho Blue**: https://morpho.org/
- **Octant**: https://octant.app/
- **Foundry Docs**: https://book.getfoundry.sh/

---

## 🛡️ Security

**⚠️ HACKATHON/DEMO VERSION**

This is a **demonstration deployment** for the Octant DeFi Hackathon 2025. The contracts are deployed on a Tenderly fork for testing purposes only.

**Not audited for production use.** A professional security audit is required before deploying with real funds on mainnet.

---

## 📄 License

GPL-2.0-or-later

---

## 🏆 Hackathon Submission

### Innovation
- Novel integration of DeFi savings with public goods funding
- Gamifies long-term saving behavior
- Makes yield generation accessible to everyone

### Technical Implementation
- Clean, modular architecture
- ERC4626 standard compliance
- Morpho Blue integration for capital efficiency
- Comprehensive test suite (96% coverage)

### Impact
- Encourages financial responsibility
- Generates sustainable funding for public goods
- Bridges personal finance and philanthropy

---

## 👤 Author

Built by [@harfi] for Octant DeFi Hackathon 2025

---

## 🎉 Try It Now!

1. Visit the [Tenderly Dashboard](https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff)
2. Get test ETH for gas (Tenderly provides it automatically)
3. Use the contract addresses above to interact
4. Create your first savings goal!

**Happy Saving! 🚀💰**
