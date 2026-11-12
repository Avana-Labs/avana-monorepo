// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The snapshot reader on a chain with several Hubs: every row is keyed by its Hub, two Lend Spokes on one Hub and a
// third on another are read, a Hub-to-Hub credit line is reported, the Hub identities hold per Hub asset, and a Hub
// the MarketRegistry records after start-up appears with its Lend Spoke, Coverage Spoke and CDP Spoke at the next read
// with the same deployment.

import { describe, expect, it } from "vitest";
import {
  CDP_A,
  CDP_B,
  CDP_C,
  COV_C,
  HUB_A,
  HUB_B,
  HUB_C,
  LEND_A,
  LEND_A2,
  LEND_B,
  LEND_C,
  USDC,
  type FakeChain,
  fakeChainClient,
  fixtureHubsChain,
  fixtureHubsDeployment,
} from "../src/views/fixtures.ts";
import { reconcileHubAsset } from "../src/views/math.ts";
import { readChainSnapshot } from "../src/views/snapshot.ts";
import type { Address } from "../src/views/types.ts";

const at = { blockNumber: 100n, timestamp: 1_767_225_600 };
const read = (chain: FakeChain = fixtureHubsChain.start) => readChainSnapshot(fakeChainClient(chain), fixtureHubsDeployment, at);
const six = (whole: number) => (BigInt(whole) * 10n ** 6n).toString();

describe("a chain with two Hubs and three Lend Spokes", () => {
  it("lists each Hub with its label, tier, Lend Spokes, CDP Spokes and lend assets", async () => {
    const snap = await read();
    expect(snap.hubs.map((h) => [h.hub, h.label, h.tier, h.recorded, h.assetCount, h.lendAssetIds, h.lendSpokes, h.cdpSpokes])).toEqual([
      [HUB_A, "Stable", 1, true, 3, ["0", "1"], [LEND_A, LEND_A2], [CDP_A]],
      [HUB_B, "Core", 2, true, 2, ["0", "1"], [LEND_B], [CDP_B]],
    ]);
  });

  it("keys every Hub asset by its Hub, so the same token on two Hubs is two rows", async () => {
    const snap = await read();
    expect(snap.hubAssets.map((a) => `${a.hub}:${a.assetId}`)).toEqual([`${HUB_A}:0`, `${HUB_A}:1`, `${HUB_B}:0`, `${HUB_B}:1`]);
    const usdc = snap.hubAssets.filter((a) => a.underlying === USDC);
    expect(usdc.map((a) => [a.hub, a.added, a.owed, a.liquidity])).toEqual([
      [HUB_A, six(10_000_000), six(3_000_000), six(7_000_000)],
      [HUB_B, six(6_000_000), six(2_000_000), six(4_000_000)],
    ]);
    expect(usdc.map((a) => a.priceUsd8)).toEqual(["100000000", "100010000"]);
  });

  it("reads both Lend Spokes of one Hub asset and prices it at the manifest's first", async () => {
    const a0 = (await read()).hubAssets[0]!;
    expect(a0.lend).toEqual({ spoke: LEND_A, reserveId: "0", paused: false, frozen: false });
    expect(a0.lendReserves).toEqual([
      { spoke: LEND_A, reserveId: "0", paused: false, frozen: false },
      { spoke: LEND_A2, reserveId: "0", paused: false, frozen: true },
    ]);
  });

  it("classifies each Spoke on each Hub asset, a CDP Spoke drawing from another Hub included", async () => {
    const snap = await read();
    const kinds = (hub: Address, assetId: string) => snap.slices.filter((s) => s.hub === hub && s.assetId === assetId).map((s) => [s.spoke, s.kind, s.homeHub]);
    expect(kinds(HUB_A, "0").map(([, kind]) => kind)).toEqual(["lend", "lend", "coverage", "feeReceiver", "cdp"]);
    expect(kinds(HUB_B, "0")).toEqual([
      [LEND_B, "lend", "0x0000000000000000000000000000000000000000"],
      [CDP_B, "cdp", HUB_B],
      [CDP_A, "cdp", HUB_A],
    ]);
  });

  it("holds the Hub identities on every Hub asset of every Hub", async () => {
    const snap = await read();
    for (const a of snap.hubAssets) {
      const r = reconcileHubAsset(a, snap.slices);
      expect([a.hub, a.assetId, r.owedReconciles, r.addedReconciles, r.onlyCdpDraws, r.balanceHolds]).toEqual([a.hub, a.assetId, true, true, true, true]);
    }
  });

  it("reports the Hub-to-Hub credit line with its registry cap; the draw stays in the slice", async () => {
    const snap = await read();
    expect(snap.creditLines).toEqual([
      { chainId: 1, fundingHub: HUB_B, assetId: "0", asset: USDC, spoke: CDP_A, homeHub: HUB_A, cap: six(1_000_000), total: six(1_000_000), enabled: true, blockNumber: "100" },
    ]);
    const draw = snap.slices.find((s) => s.hub === HUB_B && s.spoke === CDP_A)!;
    expect(draw.owed).toBe(six(500_000));
  });

  it("reads each CDP Spoke's debt reserves with the Hub that funds them", async () => {
    const snap = await read();
    expect(snap.spokeReserves.map((r) => [r.spoke, r.reserveId, r.hub, r.assetId])).toEqual([
      [CDP_A, "1", HUB_A, "0"],
      [CDP_A, "2", HUB_A, "1"],
      [CDP_A, "3", HUB_B, "0"],
      [CDP_B, "1", HUB_B, "0"],
      [CDP_B, "2", HUB_B, "1"],
    ]);
  });

  it("does not take a supply-shaped Spoke on a manifest Hub for a Lend Spoke", async () => {
    const stranger = "0x5100000000000000000000000000000000000001" as Address;
    const chain: FakeChain = {
      ...fixtureHubsChain.start,
      hubs: fixtureHubsChain.start.hubs.map((h) =>
        h.hub !== HUB_A ? h : { ...h, assets: h.assets.map((a, i) => (i !== 1 ? a : { ...a, slices: [...a.slices, { spoke: stranger, added: 0n, owed: 0n, addCap: 10, drawCap: 0 }] })) },
      ),
    };
    const snap = await read(chain);
    expect(snap.slices.find((s) => s.spoke === stranger)?.kind).toBe("other");
    expect(snap.hubs[0]!.lendSpokes).toEqual([LEND_A, LEND_A2]);
  });

  it("refuses a Lend Spoke reserve on a Hub that is neither in the manifest nor recorded", async () => {
    const chain: FakeChain = { ...fixtureHubsChain.start, recordedHubs: [HUB_A], hubs: [fixtureHubsChain.start.hubs[0]!, fixtureHubsChain.start.hubs[1]!] };
    const dep = { ...fixtureHubsDeployment, hubs: [fixtureHubsDeployment.hubs[0]!] };
    await expect(readChainSnapshot(fakeChainClient(chain), dep, at)).rejects.toThrow(/neither in the manifest nor recorded/);
  });
});

describe("a Hub recorded after start-up", () => {
  it("appears at the next read with the same deployment, with its Lend, Coverage and CDP Spokes found on chain", async () => {
    const before = await read(fixtureHubsChain.start);
    const after = await read(fixtureHubsChain.later);
    expect(before.hubs.map((h) => h.hub)).toEqual([HUB_A, HUB_B]);
    expect(after.hubs.map((h) => h.hub)).toEqual([HUB_A, HUB_B, HUB_C]);
    expect(after.hubs[2]).toMatchObject({ hub: HUB_C, label: null, tier: 3, recorded: true, lendAssetIds: ["0"], lendSpokes: [LEND_C], cdpSpokes: [CDP_C] });

    const c0 = after.hubAssets.find((a) => a.hub === HUB_C)!;
    expect([c0.assetId, c0.underlying, c0.added, c0.owed, c0.priceUsd8, c0.lend.spoke]).toEqual(["0", USDC, six(2_000_000), six(500_000), "100000000", LEND_C]);
    expect(after.slices.filter((s) => s.hub === HUB_C).map((s) => s.kind)).toEqual(["lend", "coverage", "feeReceiver", "cdp"]);
    expect(after.slices.find((s) => s.spoke === COV_C)!.kind).toBe("coverage");
    expect(reconcileHubAsset(c0, after.slices).balanceHolds).toBe(true);
    expect(after.spokeReserves.filter((r) => r.spoke === CDP_C).map((r) => [r.hub, r.assetId])).toEqual([[HUB_C, "0"]]);
    expect(after.markets.map((m) => [m.marketId, m.hub, m.spoke])).toEqual([
      ["1", HUB_A, CDP_A],
      ["2", HUB_C, CDP_C],
    ]);
    // Rows of the Hubs that were there before do not change.
    expect(after.hubAssets.filter((a) => a.hub !== HUB_C)).toEqual(before.hubAssets);
  });

  it("does not take the new Hub's Coverage Spoke for a Lend Spoke when the registry has not named it", async () => {
    const later = fixtureHubsChain.later;
    const chain: FakeChain = { ...later, hubs: later.hubs.map((h) => (h.hub !== HUB_C ? h : { ...h, assets: h.assets.map(({ coverageSpoke: _, ...a }) => a) })) };
    const snap = await read(chain);
    expect(snap.hubs[2]!.lendSpokes).toEqual([LEND_C]);
    expect(snap.slices.find((s) => s.spoke === COV_C)!.kind).toBe("other");
  });
});
