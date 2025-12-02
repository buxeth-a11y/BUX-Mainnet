# BUX Mainnet Contracts

BUX is an Ethereum-based reward system that uses a Uniswap v4 hook to fund automated hourly and daily ETH prize draws.

## Overview

Every swap on the BUX/ETH pool contributes to prize pools that are distributed back to token holders through provably fair draws. Winners are selected using weighted random selection based on BUX holdings, with verifiable randomness from Chainlink VRF.

## Contracts

| Contract | Description |
|----------|-------------|
| **ActionFundingHook.sol** | Uniswap v4 hook that captures fees from BUX/ETH swaps |
| **BUXAction.sol** | Action contract with Chainlink VRF/Automation integration |
| **BUXToken.sol** | ERC20 token with integrated sortition weight management |
| **SortitionIndex.sol** | O(log N) weighted random selection using Fenwick tree |
| **DevFeeSplitter.sol** | Pull-based fee distribution to dev wallets |
| **Create2Factory.sol** | Deterministic deployment for hook address mining |

## Hook Details

- **Permission Flags:** `0x00CC` (beforeSwap, afterSwap with delta returns)
- **Fee Structure:** 12.25% total
  - 7.9% to hourly lottery pot
  - 3.5% to daily lottery pot
  - 0.85% to development/operations

## Security

- **Audit:** [Hashlock Security Audit](https://bux.life/BUX%20Smart%20Contract%20Audit%20-%20Final%20Report.pdf)
- **Ownership:** Multi-signature Safe (Gnosis Safe)

## Integrations

- **Chainlink VRF** - Verifiable random winner selection
- **Chainlink Automation** - Trustless automated draw execution
- **Uniswap v4** - Hook-based fee capture from swaps

## Deployed Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| BUXToken | `0xb6cbFfeab1434a0D73F1706c1389378325feBB96` |
| ActionFundingHook | `0x00BBc6fC07342Cf80d14b60695Cf0E1Aa8dE00CC` |
| BUXAction | `0xEE94957C2821B122F9e0c69805A5BA05132d1990` |
| SortitionIndex | `0x6b36b47a29dAd57f9798088afC0332fa83Ba93CE` |
| DevFeeSplitter | `0x003347e13F13ff4fd5d14AD6CFfE8Fe15319c916` |
| Pool | `0x26b73e77f7b2cfc05d28a8978b917eced1cdf7915862292cfbb507731d5120fd` |

## Links

- Website: https://bux.life
- Audit Report: https://bux.life/BUX%20Smart%20Contract%20Audit%20-%20Final%20Report.pdf

## License

UNLICENSED - All rights reserved.
