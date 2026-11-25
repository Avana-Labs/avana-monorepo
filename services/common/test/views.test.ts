// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hub accounting identities on the fixture snapshot, cap room and shared liquidity, and display conversions. The
// snapshot reader runs against the in-memory chain in hubs.test.ts.

import { describe, expect, it } from "vitest";
import { FIXTURE_U, FIXTURE_X, fixtureHubAsset, fixtureSlices } from "../src/views/fixtures.ts";
import {
  MAX_SPOKE_CAP,
  assetBorrowable,
  capRoom,
  ceilDiv,
  marketBorrowRateRay,
  rayToAprPct,
  rayToApyPct,
  reconcileHubAsset,
  spokeHeadroom,
  supplyRateRay,
  tokens,
  usd,
  utilizationBps,
} from "../src/views/math.ts";
import type { HubAssetRow, HubAssetSpokeRow } from "../src/views/types.ts";

const u = (whole: number) => BigInt(whole) * 1_000_000n;
const cdp = (spoke: string) => fixtureSlices.find((s) => s.spoke === spoke)!;

describe("reconciliation of Spoke slices to Hub totals", () => {
  it("holds on the fixture: CDP owed, every slice's added and the Hub balance", () => {
    const r = reconcileHubAsset(fixtureHubAsset, fixtureSlices);
    expect(r.cdpOwed).toBe(u(3_000_000) + 1n);
    expect(r.owedGap).toBe(1n);
    expect(r.owedReconciles).toBe(true);
    expect(r.addedGap).toBe(0n);
    expect(r.addedReconciles).toBe(true);
    expect(r.onlyCdpDraws).toBe(true);
    expect(r.balanceHolds).toBe(true);
    expect(r.addedByKind.lend + r.addedByKind.coverage + r.addedByKind.feeReceiver).toBe(r.hubAdded);
  });

  it("flags a Spoke slice that is short of the Hub's owed amount", () => {
    const short = fixtureSlices.map((s) => (s.spoke === FIXTURE_X ? { ...s, owed: (u(2_000_000) - 5n).toString() } : s));
    expect(reconcileHubAsset(fixtureHubAsset, short).owedReconciles).toBe(false);
  });

  it("flags a draw by a Spoke that is not a CDP Spoke", () => {
    const bad = fixtureSlices.map((s) => (s.kind === "lend" ? { ...s, owed: "1" } : s));
    expect(reconcileHubAsset(fixtureHubAsset, bad).onlyCdpDraws).toBe(false);
  });

  it("refuses slices read at another block", () => {
    const stale = fixtureSlices.map((s, i) => (i === 0 ? { ...s, blockNumber: "1" } : s));
    expect(() => reconcileHubAsset(fixtureHubAsset, stale)).toThrow(/another block/);
  });

  it("keeps the balance after a deficit is reported: owed falls, added and liquidity stay", () => {
    const asset: HubAssetRow = { ...fixtureHubAsset, owed: u(2_950_000).toString(), deficit: u(50_000).toString() };
    const slices = fixtureSlices.map((s) => (s.spoke === FIXTURE_X ? { ...s, owed: u(1_950_000).toString(), deficit: u(50_000).toString() } : s));
    const r = reconcileHubAsset(asset, slices);
    expect(r.balanceHolds).toBe(true);
    expect(r.owedReconciles).toBe(true);
    expect(capRoom(slices.find((s) => s.spoke === FIXTURE_X)!, 6)).toBe(u(1_000_000));
  });
});

describe("cap room and shared liquidity", () => {
  it("gives each Spoke min(cap room, liquidity)", () => {
    expect(capRoom(cdp(FIXTURE_U), 6)).toBe(u(3_000_000) - 1n);
    expect(spokeHeadroom(cdp(FIXTURE_X), fixtureHubAsset)).toBe(u(1_000_000));
  });

  it("bounds the asset's total by the one liquidity both Spokes share", () => {
    expect(assetBorrowable(fixtureHubAsset, fixtureSlices)).toBe(u(4_000_000) - 1n);
    const drained = { ...fixtureHubAsset, liquidity: u(2_000_000).toString() };
    expect(assetBorrowable(drained, fixtureSlices)).toBe(u(2_000_000));
    expect(spokeHeadroom(cdp(FIXTURE_U), drained) + spokeHeadroom(cdp(FIXTURE_X), drained)).toBe(u(3_000_000));
  });

  it("treats the maximum cap as unlimited and an over-drawn cap as zero room", () => {
    const open: HubAssetSpokeRow = { ...cdp(FIXTURE_U), drawCap: MAX_SPOKE_CAP.toString() };
    expect(capRoom(open, 6)).toBeNull();
    expect(assetBorrowable(fixtureHubAsset, [open])).toBe(u(7_000_000));
    expect(capRoom({ ...cdp(FIXTURE_U), drawCap: "999999" }, 6)).toBe(0n);
  });
});

describe("rates and display", () => {
  it("computes utilization and the supply rate as the Lens does", () => {
    expect(utilizationBps(600n, 1_000n)).toBe(6_000);
    expect(utilizationBps(1n, 0n)).toBe(0);
    // 8 % drawn rate, 600 owed of 1,000 added, 10 % liquidity fee → 4.32 %.
    expect(supplyRateRay(8n * 10n ** 25n, 600n, 1_000n, 1_000)).toBe(432n * 10n ** 23n);
  });

  it("converts rates to APR and continuous-compounding APY", () => {
    expect(rayToAprPct(6n * 10n ** 25n)).toBeCloseTo(6, 10);
    expect(rayToApyPct(6n * 10n ** 25n)).toBeCloseTo(6.1837, 3);
  });

  it("charges a market's borrowers drawnRate × (1 + collateralRisk), rounded up", () => {
    expect(marketBorrowRateRay(6n * 10n ** 25n, 500)).toBe(63n * 10n ** 24n);
    expect(marketBorrowRateRay(1n, 1)).toBe(2n);
  });

  it("values base units at the 8-decimal price", () => {
    expect(usd(u(1_234), 6, 99_990_000n)).toBeCloseTo(1_233.8766, 6);
    expect(tokens(1_500_000n, 6)).toBe(1.5);
    expect(ceilDiv(0n, 3n)).toBe(0n);
    expect(ceilDiv(7n, 3n)).toBe(3n);
  });
});
