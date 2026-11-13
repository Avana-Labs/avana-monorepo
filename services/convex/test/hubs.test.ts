// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Lend and Hub views on a chain with several Hubs, from rows the snapshot reader reads off the fixture chain:
// totals add every Hub, the breakdowns keep each Hub apart, the same token on two Hubs has two pages, a Hub-to-Hub
// credit line shows its cap, draw and headroom on both Hubs, and a Hub recorded after start-up joins the totals.

import { describe, expect, it } from "vitest";
import {
  CDP_A,
  HUB_A,
  HUB_B,
  HUB_C,
  LEND_A,
  LEND_A2,
  SPEED_MORE_AT,
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
import { type World, creditLineViews, hubLabelOf, priceAsset, symbolOf } from "../convex/model.ts";

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
    creditLines: snap.creditLines.map((l) => ({ ...l, updatedAt: 0 })),
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

describe("Hub-to-Hub credit lines", () => {
  it("shows the line's cap, draw and headroom, joined with the Spoke's slice on the funding Hub", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const [line] = creditLineViews(w, () => true);
    expect(line).toMatchObject({ fundingHub: HUB_B, fundingHubLabel: "Core", homeHub: HUB_A, homeHubLabel: "Stable", spoke: CDP_A, symbol: "USDC", enabled: true, usedPct: 50 });
    expect(line!.capUsd).toBeCloseTo(1_000_100, 6);
    expect(line!.owedUsd).toBeCloseTo(500_050, 6);
    // min(cap − owed = 500,000, draw cap room 1,000,000 − 500,000, Hub B liquidity 4,000,000), at Hub B's price.
    expect(line!.headroomUsd).toBeCloseTo(500_050, 6);
  });

  it("lists the line on the funding Hub as funded and on the home Hub as drawn", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const lines = creditLineViews(w, () => true);
    const label = (h: { hub: string }) => hubLabelOf(w, 1, h.hub);
    const b = hubSummary(w.hubsByKey.get(`1:${HUB_B}`)!, "Core", w.hubAssets, lines.filter((l) => l.fundingHub === HUB_B), lines.filter((l) => l.homeHub === HUB_B));
    const a = hubSummary(w.hubsByKey.get(`1:${HUB_A}`)!, "Stable", w.hubAssets, lines.filter((l) => l.fundingHub === HUB_A), lines.filter((l) => l.homeHub === HUB_A));
    expect([b.fundsLines.length, b.drawsOnLines.length, a.fundsLines.length, a.drawsOnLines.length]).toEqual([1, 0, 0, 1]);
    expect(label(b)).toBe("Core");
    expect(params(w, HUB_B).find((p) => p.id === "otherHubDraws")!.value).toBe("500,000 USDC");
    expect(params(w, HUB_A).find((p) => p.id === "otherHubDraws")!.value).toBe("0 USDC");
  });

  it("adds the Borrow asset pages of a funding Hub asset, the line's included, up to the Lend page's borrowed", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const asset = w.hubAssets.find((x) => x.hub === HUB_B && x.underlying === USDC)!;
    const pages = w.reserves
      .filter((r) => r.hub === HUB_B && r.assetId === asset.assetId)
      .map((r) => assetSnapshot(r, w.slices.find((s) => s.hub === r.hub && s.assetId === r.assetId && s.spoke === r.spoke)!, asset, null, "USDC", r.spoke, "Core"));
    expect(pages.map((p) => p.hubId)).toEqual([HUB_B, HUB_B]);
    expect(pages.reduce((acc, p) => acc + p.borrowedUsd, 0)).toBeCloseTo(lendSnapshot(asset, null, "USDC").borrowedUsd, 6);
    expect(reconcileHubAsset(asset, w.slices).owedReconciles).toBe(true);
  });
});

describe("a Hub recorded after start-up", () => {
  it("joins the totals, the breakdowns and the Lend pages at the next refresh", async () => {
    const before = totalsOf(worldOf(await read(fixtureHubsChain.start)));
    const w = worldOf(await read(fixtureHubsChain.later));
    const after = totalsOf(w);
    expect(after.hubCount).toBe(3);
    const c = after.byHub.find((h) => h.hub === HUB_C)!;
    // Hub C's USDC: 2,050,000 added, the DAO deficit offset's 50,000 included.
    expect(c).toMatchObject({ label: "hub-aa0000", slug: "ethereum-hub-aa0000", tier: 3, lendAssets: 1, suppliedUsd: 2_050_000, borrowedUsd: 500_000 });
    expect(after.suppliedUsd).toBeCloseTo(before.suppliedUsd + 2_050_000, 6);
    expect(after.byToken.find((x) => x.symbol === "USDC")!.hubs.map((h) => h.label)).toEqual(["Stable", "Core", "hub-aa0000"]);
    expect(w.hubAssets.find((a) => a.hub === HUB_C)!.slug).toBe("ethereum-hub-aa0000-usdc");
  });
});

describe("assets a pool can borrow (BOR-024)", () => {
  it("shows each debt reserve's amount available now and when more frees up", async () => {
    const w = worldOf(await read(fixtureHubsChain.start));
    const rows = readPoolBorrowables(w, "ethereum-market-1");
    expect(rows.map((r) => [r.symbol, r.availableNow, r.availableNowUsd, r.moreFrom])).toEqual([
      ["USDC", 500_000, 500_000, new Date(SPEED_MORE_AT * 1_000).toISOString()],
      ["USDC", 500_000, 500_050, new Date(SPEED_MORE_AT * 1_000).toISOString()],
      ["USDT", 500_000, 499_950, new Date(SPEED_MORE_AT * 1_000).toISOString()],
    ]);
  });

  it("shows no amount when the Lens refuses the speed read", async () => {
    const w = worldOf(await read({ ...fixtureHubsChain.start, locked: true }));
    expect(readPoolBorrowables(w, "ethereum-market-1").map((r) => [r.availableNow, r.moreFrom])).toEqual([
      [null, null],
      [null, null],
      [null, null],
    ]);
  });
});

function params(w: World, hub: string) {
  const a = w.hubAssets.find((x) => x.hub === hub && x.underlying === USDC)!;
  return lendRiskParameters(a.slug, a, w.slices.filter((s) => s.hub === a.hub && s.assetId === a.assetId), "USDC").parameters;
}
