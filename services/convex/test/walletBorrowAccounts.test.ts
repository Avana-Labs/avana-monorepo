// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What the app needs to read a wallet's Borrow accounts from the chain: each account's pool slug and its Spoke's debt
// reserves with their asset slug, decimals and USD price.

import { describe, expect, it } from "vitest";
import { fixtureHubAsset, fixtureMarkets, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import { hubAssetKey } from "../convex/lib/pages.ts";
import type { World } from "../convex/model.ts";
import { borrowAccountRefs } from "../convex/wallet/positions.ts";

const asset = { ...fixtureHubAsset, slug: "ethereum-usdc", updatedAt: 0 };
const market = { ...fixtureMarkets[0]!, slug: "ethereum-usdc-usdt", updatedAt: 0 };
const reserves = fixtureSpokeReserves.map((r) => ({ ...r, slug: `asset-${r.reserveId}`, updatedAt: 0 }));
const world = {
  markets: [market],
  reserves,
  hubAssets: [asset],
  assetsByKey: new Map([[hubAssetKey(asset), asset]]),
  hubsByKey: new Map(),
  content: [],
} as unknown as World;
const account = { chainId: market.chainId, marketId: market.marketId, spoke: market.spoke, proxy: "0x00000000000000000000000000000000000000b1" };

describe("wallet borrow accounts", () => {
  it("names each account's pool and its Spoke's debt reserves", () => {
    const refs = borrowAccountRefs(world, [account]);
    expect(refs.accounts).toEqual([{ ...account, poolSlug: market.slug }]);
    const own = reserves.filter((r) => r.chainId === market.chainId && r.spoke === market.spoke);
    expect(refs.debtReserves.map((r) => r.assetSlug)).toEqual(own.map((r) => r.slug));
    const priced = refs.debtReserves.find((r) => r.asset === asset.underlying);
    if (priced) expect(priced.priceUsd8).toBe(asset.priceUsd8);
  });

  it("names every listed market and its Spoke's reserves without an account, for a first pledge", () => {
    const refs = borrowAccountRefs(world, []);
    expect(refs.accounts).toEqual([]);
    expect(refs.markets).toEqual([{ chainId: market.chainId, marketId: market.marketId, spoke: market.spoke, poolSlug: market.slug }]);
    const own = reserves.filter((r) => r.chainId === market.chainId && r.spoke === market.spoke);
    expect(refs.debtReserves).toHaveLength(own.length);
  });

  it("keeps an account whose market is not listed yet, without a pool slug", () => {
    const refs = borrowAccountRefs(world, [{ ...account, marketId: "999" }]);
    expect(refs.accounts[0]!.poolSlug).toBeNull();
  });
});
