// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The contracts the app's on-chain swap provider quotes and routes through, from the release manifest's `external`
// list: each venue's router and quoter, and the chain's tokens by symbol. A venue is listed only when the manifest
// names both its contracts (Uniswap v4 exists only on a fork of the real chain).

export interface ExternalEntry {
  readonly group: string;
  readonly name: string;
  readonly address: string;
  readonly standIn: boolean;
}

export type SwapVenue = "uniswap-v3" | "uniswap-v4" | "slipstream";

/** Manifest names of each venue's router and quoter. */
export const SWAP_VENUE_CONTRACTS: Readonly<Record<SwapVenue, { group: string; router: string; quoter: string }>> = {
  "uniswap-v3": { group: "uniswap-v3", router: "UniswapV3SwapRouter", quoter: "UniswapV3QuoterV2" },
  "uniswap-v4": { group: "uniswap-v4", router: "UniswapV4UniversalRouter", quoter: "UniswapV4Quoter" },
  slipstream: { group: "slipstream", router: "SlipstreamSwapRouter", quoter: "SlipstreamQuoterV2" },
};

export interface SwapContracts {
  readonly chainId: number;
  /** Chainlink native/USD feed (8 decimals), to value gas. */
  readonly nativeUsdFeed: string;
  readonly venues: readonly { readonly venue: SwapVenue; readonly router: string; readonly quoter: string }[];
  /** The chain's tokens, named by symbol in the manifest's "token" group. */
  readonly tokens: readonly { readonly symbol: string; readonly address: string }[];
}

export function swapContracts(chainId: number, nativeUsdFeed: string, external: readonly ExternalEntry[]): SwapContracts {
  const find = (group: string, name: string) => external.find((e) => e.group === group && e.name === name)?.address;
  const venues = (Object.keys(SWAP_VENUE_CONTRACTS) as SwapVenue[]).flatMap((venue) => {
    const c = SWAP_VENUE_CONTRACTS[venue];
    const router = find(c.group, c.router);
    const quoter = find(c.group, c.quoter);
    return router && quoter ? [{ venue, router, quoter }] : [];
  });
  const tokens = external.filter((e) => e.group === "token").map((e) => ({ symbol: e.name, address: e.address }));
  return { chainId, nativeUsdFeed, venues, tokens };
}
