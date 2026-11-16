// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What a wallet receives on each chain: the wallet part of the reference app's starting grant, at its amounts (eight
// tokens worth $12,500 each at the reference prices, after its overwrite of USDC to 25,000, GHO to 20,000, USDT to
// 15,000 and WETH to 5). Tokens are named by symbol; their addresses come from the chain's release manifest (its
// "token" group) when the grant runs. On Base the stablecoin and $12,500 lines are USD values, turned into tokens at
// the token's "<SYMBOL> / USD (primary)" feed when the grant runs.
// The starting positions (LP positions, the pledges and the debt, the lend supplies) are a later step.

import type { Address } from "viem";

export type ChainName = "ethereum" | "base";

/** One token line: whole tokens, or a USD value priced at grant time. */
export type TokenLine = { readonly symbol: string; readonly amount: string } | { readonly symbol: string; readonly usd: number };

export interface GrantSpec {
  /** Native ETH balance the wallet is set to, in ETH; it also pays the wallet's gas. */
  readonly nativeEth: string;
  readonly tokens: readonly TokenLine[];
}

/** A token line resolved against the chain: its address and whole tokens, as a decimal string. */
export interface TokenGrant {
  readonly symbol: string;
  readonly address: Address;
  readonly amount: string;
}

export const GRANTS: Readonly<Record<ChainName, GrantSpec>> = {
  ethereum: {
    nativeEth: "6.4633",
    tokens: [
      { symbol: "WETH", amount: "5" },
      { symbol: "USDC", amount: "25000" },
      { symbol: "USDT", amount: "15000" },
      { symbol: "GHO", amount: "20000" },
      { symbol: "WBTC", amount: "0.19230769" },
      { symbol: "LINK", amount: "694.4444" },
      { symbol: "AAVE", amount: "119.047619" },
    ],
  },
  base: {
    nativeEth: "6.4633",
    tokens: [
      { symbol: "WETH", amount: "5" },
      { symbol: "USDC", usd: 25_000 },
      { symbol: "USDT", usd: 15_000 },
      { symbol: "GHO", usd: 20_000 },
      { symbol: "WBTC", usd: 12_500 },
      { symbol: "LINK", usd: 12_500 },
      { symbol: "AAVE", usd: 12_500 },
    ],
  },
};
