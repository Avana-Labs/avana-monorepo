// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Lend and Hub views on a chain with several Hubs, from rows the snapshot reader reads off the fixture chain:
// totals add every Hub, the breakdowns keep each Hub apart, the same token on two Hubs has two pages, a Lend page
// shows its draw-cap coverage, and a Hub a later release step deploys joins the totals once it has code.

import { describe, expect, it } from "vitest";
import {
  CDP_B,
  HUB_A,
  HUB_B,
  HUB_C,
  LEND_A,
  LEND_A2,
  USDC,
  type FakeChain,
  fakeChainClient,
  fixtureHubsChain,
  fixtureHubsDeployment,
} from "@avana/services-common/fixtures";
import { type ChainSnapshot, readChainSnapshot, reconcileHubAsset } from "@avana/services-common/views";
import { readPoolBorrowables } from "../convex/details.ts";
import { defaultSlug, hubLabel } from "../convex/lib/format.ts";
import { hubSummary, lendTotals } from "../convex/lib/hubViews.ts";
import { assetSnapshot, hubAssetKey, lendSnapshot } from "../convex/lib/pages.ts";
import { lendRiskParameters } from "../convex/lib/riskViews.ts";
import { type World, hubLabelOf, priceAsset, symbolOf } from "../convex/model.ts";

const SYMBOLS: Record<string, string> = { [USDC]: "USDC", "0xdac17f958d2ee523a2206206994597c13d831ec7": "USDT", "0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f": "GHO" };

const read = (chain: FakeChain) => readChainSnapshot(fakeChainClient(chain), fixtureHubsDeployment, { blockNumber: 100n, timestamp: 1_767_225_600 });

/** The rows `applySnapshot` stores for one snapshot, with the default slugs it gives them, as the queries load them. */
function worldOf(snap: ChainSnapshot): World {
  const label = (hub: string) => hubLabel(snap.hubs.find((h) => h.hub === hub)?.label, hub);
  const hubs = snap.hubs.map((h) => ({ ...h, slug: defaultSlug.hub(1, label(h.hub)), updatedAt: 0 }));
  const hubAssets = snap.hubAssets.map((a) => ({ ...a, slug: defaultSlug.lend(1, label(a.hub), SYMBOLS[a.underlying] ?? a.underlying), updatedAt: 0 }));
  const reserves = snap.spokeReserves.map((r) => ({ ...r, slug: defaultSlug.asset(1, `spoke-${r.spoke.slice(2, 8)}`, SYMBOLS[r.asset] ?? r.asset), updatedAt: 0 }));
  const content = Object.entries(SYMBOLS).map(([key, symbol]) => ({ scope: "token", chainId: 1, key, slug: symbol.toLowerCase(), name: symbol, symbol }));
  return {
    hubs,
    hubAssets,
    slices: snap.slices.map((s) => ({ ...s, updatedAt: 0 })),
    reserves,
    markets: snap.markets.map((m) => ({ ...m, slug: `ethereum-market-${m.marketId}`, updatedAt: 0 })),
    debts: [],
    content: content as unknown as World["content"],
    assetsByKey: new Map(hubAssets.map((a) => [hubAssetKey(a), a])),
    hubsByKey: new Map(hubs.map((h) => [`${h.chainId}:${h.hub}`, h])),
  };
}

const totalsOf = (w: World) => lendTotals(w.hubs, w.hubAssets, (h) => hubLabelOf(w, h.chainId, h.hub), (c, t) => symbolOf(w, c, t));

describe("Lend views across Hubs", () => {
  it("gives the same token on two Hubs two Lend pages, each naming its Hub", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const usdc = w.hubAssets.filter((a) => a.underlying === USDC).map((a) => lendSnapshot(a, null, "USDC", hubLabelOf(w, 1, a.hub)));
    expect(usdc.map((r) => [r.slug, r.hubId, r.hubLabel])).toEqual([
      ["ethereum-stable-usdc", HUB_A, "Stable"],
      ["ethereum-core-usdc", HUB_B, "Core"],
    ]);
    expect(new Set(w.hubAssets.map((a) => a.slug)).size).toBe(w.hubAssets.length);
  });

  it("adds every Hub into the totals and keeps each Hub apart in the breakdowns", async () => {
    const t = totalsOf(worldOf(await read(fixtureHubsChain.start)));
    // Hub A: USDC 10,000,000 + USDT 4,000,000 × 0.9999; Hub B: USDC 6,000,000 × 1.0001 + GHO 1,000,000.
    expect(t.byHub.map((h) => [h.label, h.tier, h.lendAssets, h.suppliedUsd, h.borrowedUsd])).toEqual([
      ["Stable", 1, 2, 10_000_000 + 3_999_600, 3_000_000 + 999_900],
      ["Core", 2, 2, 6_000_600 + 1_000_000, 2_000_200],
    ]);
    expect(t.hubCount).toBe(2);
    expect(t.suppliedUsd).toBeCloseTo(t.byHub.reduce((acc, h) => acc + h.suppliedUsd, 0), 6);
    expect(t.borrowedUsd).toBeCloseTo(t.byHub.reduce((acc, h) => acc + h.borrowedUsd, 0), 6);
    expect(t.availableUsd).toBeCloseTo(t.byHub.reduce((acc, h) => acc + h.availableUsd, 0), 6);
    expect(t.utilizationPct).toBeCloseTo((t.borrowedUsd / t.suppliedUsd) * 100, 9);

    const usdc = t.byToken.find((x) => x.symbol === "USDC")!;
    expect(usdc.hubs.map((h) => [h.label, h.slug, h.suppliedUsd])).toEqual([
      ["Stable", "ethereum-stable-usdc", 10_000_000],
      ["Core", "ethereum-core-usdc", 6_000_600],
    ]);
    expect(usdc.suppliedUsd).toBe(16_000_600);
    // Supply-weighted: between the two Hubs' supply APYs.
    const [a, b] = usdc.hubs.map((h) => h.supplyApyPct) as [number, number];
    expect(usdc.supplyApyPct).toBeGreaterThan(Math.min(a, b));
    expect(usdc.supplyApyPct).toBeLessThan(Math.max(a, b));
  });

  it("sums a Hub asset's two Lend Spokes' caps and shows both reserves", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const a = w.hubAssets.find((x) => x.hub === HUB_A && x.underlying === USDC)!;
    expect(a.lendReserves.map((r) => r.spoke)).toEqual([LEND_A, LEND_A2]);
    const params = lendRiskParameters(a.slug, a, w.slices.filter((s) => s.hub === a.hub && s.assetId === a.assetId), "USDC").parameters;
    expect(params.find((p) => p.id === "supplyCap")!.value).toBe("25,000,000 USDC");
    expect(params.find((p) => p.id === "status")).toMatchObject({ label: "Lend reserves", value: "Active, Frozen" });
  });

  it("prices a token by its market's Hub, else by the lowest tier", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    expect(priceAsset(w, 1, USDC)!.hub).toBe(HUB_A);
    expect(priceAsset(w, 1, USDC, HUB_B)!.hub).toBe(HUB_B);
  });
});

describe("draw-cap coverage", () => {
  it("shows the CDP Spokes' draw-cap sum, the balance it requires and the funded balance on the Lend page", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const value = (id: string) => params(w, HUB_A).find((p) => p.id === id)!.value;
    // CDP A's draw cap of 4,000,000 USDC at the fake RiskModule's 5 % needs 200,000 USDC, the First-Loss Reserve's balance.
    expect([value("borrowCapacity"), value("coverageRequired"), value("firstLoss"), value("coverageBound")]).toEqual(["4,000,000 USDC", "200,000 USDC", "200,000 USDC", "Holds"]);
    // Hub B's USDC has no First-Loss Reserve, so no coverage figures.
    expect(params(w, HUB_B).find((p) => p.id === "coverageRequired")!.value).toBe("—");
    expect(hubSummary(w.hubsByKey.get(`1:${HUB_B}`)!, "Core", w.hubAssets)).toMatchObject({ label: "Core", cdpSpokes: [CDP_B] });
  });

  it("adds the Borrow asset pages of a Hub asset up to the Lend page's borrowed", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const asset = w.hubAssets.find((x) => x.hub === HUB_B && x.underlying === USDC)!;
    const reserves = w.reserves.filter((r) => r.hub === HUB_B && r.assetId === asset.assetId);
    const pages = reserves.map((r) => assetSnapshot(r, w.slices.find((s) => s.hub === r.hub && s.assetId === r.assetId && s.spoke === r.spoke)!, asset, null, "USDC", "Core"));
    expect(pages.map((p) => p.hubId)).toEqual([HUB_B, HUB_B]);
    // Keyed by the Spoke's address, as pool rows are, so a market joins its own Spoke's debt reserves.
    expect(pages.map((p) => p.spokeId)).toEqual(reserves.map((r) => r.spoke));
    expect(pages.reduce((acc, p) => acc + p.borrowedUsd, 0)).toBeCloseTo(lendSnapshot(asset, null, "USDC").borrowedUsd, 6);
    expect(reconcileHubAsset(asset, w.slices).owedReconciles).toBe(true);
  });
});

describe("a Hub a later release step deploys", () => {
  it("joins the totals, the breakdowns and the Lend pages once it has code", async () => {
    const before = totalsOf(worldOf(await read(fixtureHubsChain.start)));
    const w = worldOf(await read(fixtureHubsChain.later));
    const after = totalsOf(w);
    expect(after.hubCount).toBe(3);
    const c = after.byHub.find((h) => h.hub === HUB_C)!;
    // Hub C's USDC: 2,050,000 added, the DAO deficit offset's 50,000 included.
    expect(c).toMatchObject({ label: "Edge", slug: "ethereum-edge", tier: 3, lendAssets: 1, suppliedUsd: 2_050_000, borrowedUsd: 500_000 });
    expect(after.suppliedUsd).toBeCloseTo(before.suppliedUsd + 2_050_000, 6);
    expect(after.byToken.find((x) => x.symbol === "USDC")!.hubs.map((h) => h.label)).toEqual(["Stable", "Core", "Edge"]);
    expect(w.hubAssets.find((a) => a.hub === HUB_C)!.slug).toBe("ethereum-edge-usdc");
  });
});

describe("assets a pool can borrow", () => {
  it("lists every borrowable debt reserve of the market's Spoke with its rate and its Hub's liquidity", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const rows = readPoolBorrowables(w, "ethereum-market-1");
    // Hub A USDC 7,000,000, Hub B USDC 4,000,000, Hub A USDT 3,000,000 of liquidity; no speed window frees up later.
    expect(rows.map((r) => [r.symbol, r.availableNow, r.moreFrom]).sort()).toEqual([
      ["USDC", 4_000_000, null],
      ["USDC", 7_000_000, null],
      ["USDT", 3_000_000, null],
    ]);
    expect(rows.every((r) => r.borrowAprPct > 0)).toBe(true);
  });
});

function params(w: World, hub: string) {
  const a = w.hubAssets.find((x) => x.hub === hub && x.underlying === USDC)!;
  return lendRiskParameters(a.slug, a, w.slices.filter((s) => s.hub === a.hub && s.assetId === a.assetId), "USDC").parameters;
}
