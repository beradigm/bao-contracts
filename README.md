# BAO.fun DAO Fundraising Platform

**A comprehensive, secure smart contract suite for decentralized fundraising on Berachain.**

![Version](https://img.shields.io/badge/Solidity-0.8.29-blue)
![License](https://img.shields.io/badge/License-MIT-green)

## Overview

The BAO.fun platform enables DAO and project fundraising with multi-token contribution support, precise equity tracking, and robust fund management capabilities. The platform is built on Solidity with Foundry testing framework and integrates Pyth Network for accurate price feeds.

## Key Features

- **Multi-token Fundraising**: Accept contributions in BERA (native), iBGT, Honey, and other tokens
- **Price Feed Integration**: Pyth Network oracle integration for accurate USD valuation
- **Equity NFT System**: Contributor ownership represented as NFTs with on-chain metadata
- **Royalty Distribution**: NFT royalty distribution between protocol admin and DAO managers
- **Robust Access Controls**: Role-based permission system with configurable controls
- **Emergency Functions**: Fund recovery mechanisms and administrative safety controls

## Contract Architecture

### Core Contracts

- **BAO.sol**: Primary fundraising contract
  - Handles multi-token contributions
  - Tracks contributor equity
  - Manages fundraising lifecycle
  - Price feed integration

- **EquityNFT.sol**: Ownership representation
  - ERC721-based equity shares
  - On-chain metadata
  - Royalty distribution (ERC2981)
  - Dynamic URI generation

- **BaosFactory.sol**: Deployment factory
  - Deploy new DAO instances
  - Configure protocol parameters
  - Deploy distribution contracts

- **BaosDistribution.sol**: Fund distribution
  - Distribute ETH/tokens to NFT holders
  - Proportional distribution based on equity shares

## Requirements

- Solidity 0.8.29
- Foundry (for testing and deployment)
- Node.js 16+
- OpenZeppelin Contracts v5.3.0
- Pyth Network SDK integration

## Setup

### Environment

Create a `.env` file with the following variables:

```
PRIVATE_KEY=your_private_key
BERAKEY_RPC_URL=your_berachain_rpc_url
PYTH_CONTRACT_ADDRESS=pyth_contract_address
ETH_USD_PRICE_FEED=pyth_eth_usd_price_feed_id
IBGT_USD_PRICE_FEED=pyth_ibgt_usd_price_feed_id
HONEY_USD_PRICE_FEED=pyth_honey_usd_price_feed_id
```

### Installation

```shell
# Clone the repository
git clone https://github.com/your-username/baosdotfun.git
cd baosdotfun/contract

# Install dependencies
forge install

# Build contracts
forge build
```

## Testing

```shell
# Run all tests
forge test

# Run specific test file
forge test --match-contract BAOTest

# Run with verbosity for debugging
forge test -vvv
```

## Deployment

```shell
# Deploy to local network
forge script script/DeployBAO.s.sol --rpc-url localhost --broadcast

# Deploy to Berachain
forge script script/DeployBAO.s.sol --rpc-url $BERAKEY_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## Usage Flow

1. **Factory Deployment**: Deploy BaosFactory with protocol admin address
2. **DAO Creation**: Create new DAO with fundraising goals and token configuration
3. **Contribution**: Users contribute tokens to the BAO contract
4. **Equity NFT**: Contributors receive EquityNFT representing their share
5. **Distribution**: Deploy BaosDistribution to distribute funds to NFT holders

## Security Features

- Price feed staleness validation
- Reentrancy protection
- Role-based access control
- Emergency fund recovery
- Comprehensive error handling

## License

MIT

