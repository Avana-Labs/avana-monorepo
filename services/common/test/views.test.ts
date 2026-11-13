// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hub accounting identities on the fixture snapshot, cap room and shared liquidity, display conversions, and the
// snapshot reader against a scripted multicall.

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

describe("snapshot reader", () => {
  const LENS = "0x9999999999999999999999999999999999999999";
  const ORACLE = "0x8888888888888888888888888888888888888888";
  const IRS = "0x7777777777777777777777777777777777777777";
  const COV = "0x3333333333333333333333333333333333333333";
  const LEND = "0x2222222222222222222222222222222222222222";
  const HUB = fixtureHubAsset.hub;
  const market = {
    marketId: 1n, status: 1, pool: "0xAAAA000000000000000000000000000000000001", poolId: `0x${"00".repeat(32)}`, tokens: [fixtureHubAsset.underlying],
    tokenDecimals: [6], feeTier: 100, tickLower: -10, tickUpper: 10, integrationId: 1, ammProtocol: `0x${"00".repeat(31)}01`,
    vaultToken: "0xBBBB000000000000000000000000000000000001", name: "USDC/USDT", symbol: "av-1", lpOracle: "0xCCCC000000000000000000000000000000000001",
    hub: HUB, spoke: FIXTURE_U, reserveId: 3n, hubAssetId: 0n, acceptedPrice: 200_000_000n, priceState: 0, suppliedUnits: 10n ** 22n,
    suppliedUsd: 2n * 10n ** 12n, collateralFactorBps: 8_000n, liquidationThresholdBps: 8_000n, maxLiquidationBonusBps: 500n, marketHeadroomUsd: 0n,
    sliceHeadroomUsd: 0n, addHeadroom: 0n, pauseState: 0, breakerReasons: 0, collateralRiskBps: 500n, liquidationFeeBps: 1_000n,
    targetHealthFactor: 11n * 10n ** 17n, healthFactorForMaxBonus: 95n * 10n ** 16n, liquidationBonusFactorBps: 5_000n, hardHealthFloor: 0n, marketUsdCap: 0n,
    topUpSliceUsd: 0n, depositorUsdCap: 0n, tokenUsdCaps: [0n], addCap: 0n, debtReserveIds: [1n], borrowRatesRay: [63n * 10n ** 24n],
  };
  const window = (limit: bigint, used: bigint, moreAt: bigint) => ({ limit, used, available: limit - used, moreAt, moreAmount: used, unavailable: false });
  const REGISTRY = "0x8000000000000000000000000000000000000001";
  const VT = "0xbbbb000000000000000000000000000000000001";
  const answers: Record<string, unknown> = {
    [`getHubs:${REGISTRY}`]: [HUB],
    [`getSpokes:${REGISTRY}`]: [FIXTURE_U],
    [`crossHubLinesEnabled:${REGISTRY}`]: false,
    [`isRecordedHub:${REGISTRY}:${HUB}`]: true,
    [`hubTier:${REGISTRY}:${HUB}`]: 1,
    [`hubOf:${REGISTRY}:${FIXTURE_U}`]: HUB,
    [`getApplicationState:${LENS}:${HUB}`]: 0,
    [`getAssetCount:${HUB}`]: 2n,
    [`getAssetUnderlyingAndDecimals:${HUB}:0`]: [VT, 18],
    [`getAssetUnderlyingAndDecimals:${HUB}:1`]: [fixtureHubAsset.underlying, 6],
    [`getAssetConfig:${HUB}:0`]: { feeReceiver: "0x4444444444444444444444444444444444444444", liquidityFee: 0, irStrategy: IRS },
    [`getSpokeCount:${HUB}:0`]: 1n,
    [`getSpokeAddress:${HUB}:0:0`]: FIXTURE_U,
    [`getSpoke:${HUB}:0:${FIXTURE_U}`]: { drawnShares: 0n, premiumShares: 0n, addedShares: 10n ** 22n, addCap: 100, drawCap: 0, active: true, halted: false, deficitRay: 0n },
    [`coverageSpokeOf:${REGISTRY}:${HUB}:${fixtureHubAsset.underlying}`]: COV,
    [`coverageSpokeOf:${REGISTRY}:${HUB}:${VT}`]: "0x0000000000000000000000000000000000000000",
    [`getReserveCount:${LEND}`]: 1n,
    [`ORACLE:${LEND}`]: ORACLE,
    [`getDebtReserves:${LENS}:${FIXTURE_U}`]: [{ spoke: FIXTURE_U, reserveId: 1n, asset: fixtureHubAsset.underlying, decimals: 6, price: 100_000_000n, fixedPrice: false, hub: HUB, hubAssetId: 1n, paused: false, frozen: false, borrowable: true, breakerReasons: 0, pauseState: 0 }],
    [`getLiquidationConfig:${FIXTURE_U}`]: { targetHealthFactor: 11n * 10n ** 17n, healthFactorForMaxBonus: 95n * 10n ** 16n, liquidationBonusFactor: 5_000 },
    [`decimals:${ORACLE}`]: 8,
    [`getReserve:${LEND}:0`]: { underlying: fixtureHubAsset.underlying, hub: HUB, assetId: 1, decimals: 6, collateralRisk: 0 },
    [`getReserveConfig:${LEND}:0`]: { paused: false, frozen: true },
    [`getReservePrice:${ORACLE}:0`]: 99_990_000n,
    [`getAddedAssets:${HUB}:1`]: u(10_000_000),
    [`getAddedShares:${HUB}:1`]: u(9_000_000),
    [`getAssetOwed:${HUB}:1`]: [u(2_990_000), u(10_000)],
    [`getAssetLiquidity:${HUB}:1`]: u(7_000_000),
    [`getAssetDeficitRay:${HUB}:1`]: 1n,
    [`getAssetAccruedFees:${HUB}:1`]: 0n,
    [`getAssetDrawnRate:${HUB}:1`]: 6n * 10n ** 25n,
    [`getAssetDrawnIndex:${HUB}:1`]: 10n ** 27n,
    [`getAssetConfig:${HUB}:1`]: { feeReceiver: "0x4444444444444444444444444444444444444444", liquidityFee: 1_000, irStrategy: IRS },
    [`getSpokeCount:${HUB}:1`]: 3n,
    [`getSpokeAddress:${HUB}:1:0`]: LEND,
    [`getSpokeAddress:${HUB}:1:1`]: COV,
    [`getSpokeAddress:${HUB}:1:2`]: FIXTURE_U,
    [`getInterestRateData:${IRS}:1`]: { optimalUsageRatio: 8_000, baseDrawnRate: 0, rateGrowthBeforeOptimal: 400, rateGrowthAfterOptimal: 6_000 },
    [`getHubAssetExposure:${LENS}:${HUB}:${fixtureHubAsset.underlying}`]: { coverageSpoke: COV, fundedBalance: u(200_000), line: u(7_000_000), coverageBoundHolds: true, uncovered: 0n, priceAdj: 10n ** 6n, spokes: [{ spoke: FIXTURE_U, homeHub: HUB, kind: 1 }], deficitOffset: "0x0000000000000000000000000000000000000000", offsetFunded: 0n },
    [`getBorrowSpeed:${LENS}:1:1`]: { market: window(10n ** 14n, 6n * 10n ** 13n, 1_200n), debt: window(u(500_000), 0n, 0n), availableNow: u(400_000), moreAt: 1_200n },
    [`LENS_MAX_PAGE:${LENS}`]: 200n,
    [`getMarkets:${LENS}:0:200`]: [market],
    [`getReserve:${FIXTURE_U}:3`]: { collateralRisk: 500 },
  };
  for (const [spoke, added, owed] of [[LEND, u(9_800_000), 0n], [COV, u(200_000), 0n], [FIXTURE_U, 0n, u(3_000_000)]] as const) {
    answers[`getSpoke:${HUB}:1:${spoke}`] = { drawnShares: owed, premiumShares: 0n, addedShares: added, addCap: 0, drawCap: spoke === FIXTURE_U ? 4_000_000 : 0, active: true, halted: false, deficitRay: 0n };
    answers[`getSpokeAddedAssets:${HUB}:1:${spoke}`] = added;
    answers[`getSpokeTotalOwed:${HUB}:1:${spoke}`] = owed;
  }
  const client = {
    async multicall(calls: readonly { address: string; functionName: string; args?: readonly unknown[] }[]) {
      return calls.map((c) => {
        const key = [c.functionName, ...[c.address, ...(c.args ?? [])].map((x) => String(x).toLowerCase())].join(":");
        const hit = answers[key];
        return hit === undefined ? { status: "failure" as const, error: new Error(key) } : { status: "success" as const, result: hit };
      });
    },
  };

  it("reads one Hub asset, its slices, the CDP reserve and the market at one block", async () => {
    const { readChainSnapshot } = await import("../src/views/snapshot.ts");
    const snap = await readChainSnapshot(client, { chainId: 1, lens: LENS, marketRegistry: REGISTRY, hubs: [{ address: HUB, label: "Stable" }], lendSpokes: [LEND], cdpSpokes: [FIXTURE_U], coverageSpokes: [] }, { blockNumber: 77n, timestamp: 1_000 });
    const asset = snap.hubAssets[0]!;
    expect(asset.priceUsd8).toBe("99990000");
    expect(asset.owed).toBe(u(3_000_000).toString());
    expect(asset.deficit).toBe("1");
    expect(asset.utilizationBps).toBe(3_000);
    expect(asset.supplyRateRay).toBe((162n * 10n ** 23n).toString());
    expect(asset.lend.frozen).toBe(true);
    expect(asset.rateCurve?.optimalUsageBps).toBe(8_000);
    expect(snap.slices.map((s) => [s.kind, s.added, s.owed])).toEqual([
      ["lend", u(9_800_000).toString(), "0"],
      ["coverage", u(200_000).toString(), "0"],
      ["cdp", "0", u(3_000_000).toString()],
    ]);
    expect(snap.spokeReserves[0]).toMatchObject({ spoke: FIXTURE_U, reserveId: "1", assetId: "1", borrowable: true });
    expect(snap.markets[0]).toMatchObject({ marketId: "1", collateralRiskBps: 500, suppliedUsd8: "2000000000000", liquidation: { liquidationBonusFactorBps: 5_000 } });
    // Borrow speed of reserve 1 (available now 400,000 USDC, more from t = 1,200); the pledge-speed read reverted.
    expect(snap.markets[0]!.borrow).toEqual([
      {
        reserveId: "1",
        borrowRateRay: (63n * 10n ** 24n).toString(),
        speed: {
          availableNow: u(400_000).toString(),
          moreAt: 1_200,
          market: { limit: "100000000000000", used: "60000000000000", available: "40000000000000", moreAt: 1_200, moreAmount: "60000000000000", unavailable: false },
          debt: { limit: u(500_000).toString(), used: "0", available: u(500_000).toString(), moreAt: 0, moreAmount: "0", unavailable: false },
        },
      },
    ]);
    expect(snap.markets[0]!.pledgeSpeed).toBeNull();
    expect(asset.exposure).toMatchObject({ deficitOffset: "0x0000000000000000000000000000000000000000", offsetFunded: "0" });
    expect(new Set([asset.blockNumber, ...snap.slices.map((s) => s.blockNumber), snap.markets[0]!.blockNumber, snap.hubs[0]!.blockNumber])).toEqual(new Set(["77"]));
    expect(snap.hubs).toEqual([
      { chainId: 1, hub: HUB, label: "Stable", tier: 1, recorded: true, applicationState: 0, assetCount: 2, lendAssetIds: ["1"], lendSpokes: [LEND], cdpSpokes: [FIXTURE_U], blockNumber: "77" },
    ]);
    expect(snap.creditLines).toEqual([]);
  });

  it("fails the whole snapshot when a required view reverts", async () => {
    const { readChainSnapshot } = await import("../src/views/snapshot.ts");
    const broken = { multicall: async (calls: readonly unknown[]) => calls.map(() => ({ status: "failure" as const, error: new Error("revert") })) };
    await expect(readChainSnapshot(broken, { chainId: 1, lens: LENS, marketRegistry: REGISTRY, hubs: [], lendSpokes: [LEND], cdpSpokes: [], coverageSpokes: [] }, { blockNumber: 1n, timestamp: 0 })).rejects.toThrow(/reverted/);
  });
});
