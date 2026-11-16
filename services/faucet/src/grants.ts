// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What a wallet receives on each chain: the wallet part of the reference app's starting grant, at its amounts (eight
// tokens worth $12,500 each at the reference prices, after its overwrite of USDC to 25,000, GHO to 20,000, USDT to
// 15,000 and WETH to 5). The chains are forks, so the tokens are the real ones at their real addresses.
// The starting positions (LP positions, the pledges and the debt, the lend supplies) are a later step.

import type { Address } from "viem";

export type ChainName = "ethereum" | "base";

export interface TokenGrant {
  readonly symbol: string;
  readonly address: Address;
  /** Whole tokens, as a decimal string; scaled by the token's own `decimals()`. */
  readonly amount: string;
}

export interface ChainGrant {
  /** Native ETH balance the wallet is set to, in ETH; it also pays the wallet's gas. */
  readonly nativeEth: string;
  readonly tokens: readonly TokenGrant[];
}

export const GRANTS: Readonly<Record<ChainName, ChainGrant>> = {
  ethereum: {
    nativeEth: "6.4633",
    tokens: [
      { symbol: "WETH", address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", amount: "5" },
      { symbol: "USDC", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", amount: "25000" },
      { symbol: "USDT", address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", amount: "15000" },
      { symbol: "GHO", address: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f", amount: "20000" },
      { symbol: "WBTC", address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", amount: "0.19230769" },
      { symbol: "LINK", address: "0x514910771AF9Ca656af840dff83E8264EcF986CA", amount: "694.4444" },
      { symbol: "AAVE", address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9", amount: "119.047619" },
    ],
  },
  // The reference app runs on one chain; which tokens a Base wallet starts with is not decided yet. Gas only until then.
  base: {
    nativeEth: "6.4633",
    tokens: [],
  },
};
