// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Lend page and the Borrow pages on one fixture snapshot: the Borrow asset pages' "borrowed via this Spoke"
// add up to the Lend page's borrowed total, both read the same Hub supply, utilization and rates, the Lend page's
// allocation by Spoke adds up to the Hub, and a Spoke's split by market adds up to the Spoke's owed amount.

import { describe, expect, it } from "vitest";
import {
  FIXTURE_U,
  FIXTURE_X,
  fixtureHubAsset,
  fixtureMarketDebt,
  fixtureMarkets,
  fixtureSlices,
  fixtureSpokeReserves,
} from "@avana/services-common/fixtures";
import { assetBorrowable, reconcileHubAsset } from "@avana/services-common/views";
import { assetSnapshot, hubAssetKey, lendSnapshot, marketAllocation, poolSnapshot, spokeAllocation, sumMarketDebt } from "../convex/lib/pages.ts";

const asset = { ...fixtureHubAsset, slug: "ethereum-usdc" };
const reserves = fixtureSpokeReserves.map((r, i) => ({ ...r, slug: i === 0 ? "ethereum-u-usdc" : "ethereum-x-usdc" }));
const markets = fixtureMarkets.map((m) => ({ ...m, slug: `ethereum-market-${m.marketId}` }));
const assets = new Map([[hubAssetKey(asset), asset]]);
const sliceOf = (spoke: string) => fixtureSlices.find((s) => s.spoke === spoke)!;

const lend = lendSnapshot(asset, null, "USDC");
const borrowU = assetSnapshot(reserves[0]!, sliceOf(FIXTURE_U), asset, null, "USDC", "u");
const borrowX = assetSnapshot(reserves[1]!, sliceOf(FIXTURE_X), asset, null, "USDC", "x");

describe("Spoke slices reconcile to the Hub totals the Lend page shows", () => {
  it("adds the Borrow asset pages' borrowed amounts up to the Lend page's, within one unit per Spoke", () => {
    expect(lend.borrowedUsd).toBe(3_000_000);
    expect(borrowU.borrowedUsd + borrowX.borrowedUsd).toBeCloseTo(lend.borrowedUsd, 5);
    expect(reconcileHubAsset(asset, fixtureSlices).owedReconciles).toBe(true);
  });

  it("shows the same Hub supply, utilization and rates on the Lend page and every Borrow asset page", () => {
    for (const b of [borrowU, borrowX]) {
      expect(b.suppliedUsd).toBe(lend.suppliedUsd);
      expect(b.utilizationPct).toBe(lend.utilizationPct);
      expect(b.supplyApyPct).toBe(lend.supplyApyPct);
      expect(b.borrowAprPct).toBe(lend.borrowAprPct);
    }
    expect(lend.utilizationPct).toBe(30);
    expect(lend.borrowAprPct).toBeCloseTo(6, 10);
  });

  it("uses the Hub's liquidity as available, never supplied − borrowed", () => {
    expect(lend.availableUsd).toBe(7_000_000);
    expect(borrowU.availableUsd).toBeCloseTo(3_000_000, 5);
    expect(borrowX.availableUsd).toBe(1_000_000);
    const drained = { ...asset, liquidity: (2_000_000n * 10n ** 6n).toString() };
    expect(assetSnapshot(reserves[0]!, sliceOf(FIXTURE_U), drained, null, "USDC", "u").availableUsd).toBe(2_000_000);
    expect(Number(assetBorrowable(drained, fixtureSlices)) / 1e6).toBe(2_000_000);
  });

  it("splits the Lend page's allocation by Spoke so the rows add up to the Hub", () => {
    const alloc = spokeAllocation(asset, fixtureSlices);
    const owed = alloc.rows.reduce((acc, r) => acc + r.owedUsd, 0);
    const added = alloc.rows.reduce((acc, r) => acc + r.addedUsd, 0);
    expect(owed).toBeCloseTo(lend.borrowedUsd, 5);
    expect(added).toBe(lend.suppliedUsd);
    expect(alloc.rows.filter((r) => r.kind === "cdp").reduce((acc, r) => acc + r.shareOfOwedPct, 0)).toBeCloseTo(100, 3);
    expect(alloc.idleUsd).toBe(lend.availableUsd);
  });
});

describe("a CDP Spoke's split by market reconciles to the Spoke's owed amount", () => {
  it("sums the market rows to the slice within one unit per account", () => {
    const sum = sumMarketDebt(fixtureMarketDebt, FIXTURE_U, "1");
    const slice = BigInt(sliceOf(FIXTURE_U).owed);
    const accounts = BigInt(fixtureMarketDebt.reduce((acc, d) => acc + d.borrowers, 0));
    expect(sum >= slice && sum - slice <= accounts).toBe(true);
  });

  it("gives the Borrow asset page's allocation shares of the Spoke's draw, summing to 100 %", () => {
    const rows = marketAllocation(reserves[0]!, asset, markets, fixtureMarketDebt, () => null);
    expect(rows.map((r) => r.poolSlug)).toEqual(["ethereum-market-1", "ethereum-market-2"]);
    expect(rows.reduce((acc, r) => acc + r.sharePct, 0)).toBeCloseTo(100, 3);
    expect(rows.reduce((acc, r) => acc + r.valueUsd, 0)).toBeCloseTo(borrowU.borrowedUsd, 4);
    // Market 1 pays 6 % × 1.05.
    expect(rows[0]!.borrowAprPct).toBeCloseTo(6.3, 10);
  });

  it("values each pool page's debt backed so the Spoke's markets add up to its Borrow asset page", () => {
    const pools = markets.map((m) =>
      poolSnapshot(m, fixtureMarketDebt.filter((d) => d.marketId === m.marketId), reserves, assets, { volumeUsd: 0, feesUsd: 0 }, null),
    );
    expect(pools.reduce((acc, p) => acc + p.borrowedUsd, 0)).toBeCloseTo(borrowU.borrowedUsd, 4);
    expect(pools[0]).toMatchObject({ scope: "pool", suppliedUsd: 2_000_000, maxLtvPct: 80, premiumBps: 500, feeTier: "0.01%", lpPriceUsd: 2 });
    expect(pools[0]!.utilizationPct).toBeCloseTo(30, 4);
  });
});
