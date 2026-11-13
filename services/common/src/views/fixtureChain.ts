// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test data only: an in-memory chain that answers the snapshot reader's view calls the way the contracts do, so the
// tests run the real reader (snapshot.ts, discovery.ts) end to end. It holds Hubs with their assets and Spokes, Lend
// Spokes with their oracles, CDP Spokes with their debt reserves, DAO deficit offsets, the MarketRegistry's records and
// Hub-to-Hub lines, and the Lens with its speed-limit views. A call to an address or function the chain does not hold
// fails, as it reverts on chain.

import type { CallResult, ContractCall, ViewClient } from "./client.ts";
import type { Address } from "./types.ts";

export interface FakeSlice {
  readonly spoke: Address;
  readonly added: bigint;
  readonly owed: bigint;
  readonly addCap: number;
  readonly drawCap: number;
  readonly active?: boolean;
  /** Set on a DAO deficit offset: the Coverage Spoke its `FIRST_LOSS_LAYER()` answers. */
  readonly firstLossLayer?: Address;
}

export interface FakeAsset {
  readonly underlying: Address;
  readonly decimals: number;
  readonly feeReceiver: Address;
  readonly liquidityFeeBps: number;
  readonly drawn: bigint;
  readonly premium: bigint;
  readonly liquidity: bigint;
  readonly drawnRateRay: bigint;
  readonly slices: readonly FakeSlice[];
  /** The registry's Coverage Spoke of (Hub, asset). */
  readonly coverageSpoke?: Address;
}

export interface FakeHub {
  readonly hub: Address;
  readonly tier: number;
  readonly assets: readonly FakeAsset[];
}

export interface FakeLendSpoke {
  readonly spoke: Address;
  readonly oracle: Address;
  readonly oracleDecimals: number;
  /** Prices in the oracle's decimals. */
  readonly reserves: readonly { readonly hub: Address; readonly assetId: number; readonly price: bigint; readonly frozen?: boolean }[];
}

export interface FakeCdpSpoke {
  readonly spoke: Address;
  readonly homeHub: Address;
  readonly debtReserves: readonly { readonly reserveId: bigint; readonly hub: Address; readonly hubAssetId: bigint; readonly asset: Address; readonly decimals: number }[];
}

export interface FakeChain {
  readonly lens: Address;
  readonly registry: Address;
  readonly rateStrategy: Address;
  readonly hubs: readonly FakeHub[];
  /** Hubs the registry has recorded; a manifest Hub may be absent. */
  readonly recordedHubs: readonly Address[];
  readonly lendSpokes: readonly FakeLendSpoke[];
  /** CDP Spokes the registry has approved. */
  readonly cdpSpokes: readonly FakeCdpSpoke[];
  readonly crossHubLines: readonly { readonly fundingHub: Address; readonly asset: Address; readonly spoke: Address; readonly cap: bigint }[];
  readonly crossHubLinesEnabled: boolean;
  readonly markets: readonly Record<string, unknown>[];
  /** The Lock is held: the Lens speed views revert `Locked()`. */
  readonly locked?: boolean;
}

/**
 * The speed windows every market answers: the market window has $750,000 of room of $1,000,000 and $250,000 frees up
 * at `SPEED_MORE_AT`; each (funding Hub, asset) window has 500,000 whole tokens of room and nothing counting; the
 * pledge window is empty with $2,500,000 of room. So `availableNow` is 500,000 whole tokens at a $1 price.
 */
export const SPEED_MORE_AT = 1_767_240_000;
const speedView = (limit: bigint, used: bigint, moreAt: number, moreAmount: bigint) => ({ limit, used, available: limit - used, moreAt: BigInt(moreAt), moreAmount, unavailable: false });

const RAY = 10n ** 27n;
const ZERO: Address = "0x0000000000000000000000000000000000000000";
const eq = (a: unknown, b: string) => String(a).toLowerCase() === b.toLowerCase();

class CallFailed extends Error {}

/** The view the chain answers for one call; throws `CallFailed` when the contract would refuse the call. */
function answer(c: FakeChain, call: ContractCall): unknown {
  const at = call.address.toLowerCase();
  const args = call.args ?? [];
  const fn = call.functionName;
  if (at === c.registry) {
    const hubOf = (sp: unknown) => c.cdpSpokes.find((x) => eq(sp, x.spoke))?.homeHub ?? ZERO;
    const lines = (hub: unknown, asset: unknown) => c.crossHubLines.filter((l) => eq(hub, l.fundingHub) && eq(asset, l.asset));
    switch (fn) {
      case "getHubs":
        return c.recordedHubs;
      case "getSpokes":
        return c.cdpSpokes.map((s) => s.spoke);
      case "crossHubLinesEnabled":
        return c.crossHubLinesEnabled;
      case "isRecordedHub":
        return c.recordedHubs.some((h) => eq(args[0], h));
      case "hubTier": {
        if (!c.recordedHubs.some((h) => eq(args[0], h))) throw new CallFailed("InvalidHub");
        return c.hubs.find((h) => eq(args[0], h.hub))!.tier;
      }
      case "hubOf":
        return hubOf(args[0]);
      case "coverageSpokeOf":
        return c.hubs.find((h) => eq(args[0], h.hub))?.assets.find((a) => eq(args[1], a.underlying))?.coverageSpoke ?? ZERO;
      case "crossHubLineCap":
        return lines(args[0], args[1]).find((l) => eq(args[2], l.spoke))?.cap ?? 0n;
      case "crossHubLineTotal":
        return lines(args[0], args[1]).reduce((acc, l) => acc + l.cap, 0n);
    }
  }
  const hub = c.hubs.find((h) => h.hub === at);
  if (hub) {
    if (fn === "getAssetCount") return BigInt(hub.assets.length);
    const a = hub.assets[Number(args[0])];
    if (!a) throw new CallFailed("AssetNotListed");
    const slice = (sp: unknown) => {
      const x = a.slices.find((y) => eq(sp, y.spoke));
      if (!x) throw new CallFailed("SpokeNotListed");
      return x;
    };
    const added = a.slices.reduce((acc, x) => acc + x.added, 0n);
    switch (fn) {
      case "getAssetUnderlyingAndDecimals":
        return [a.underlying, a.decimals];
      case "getAssetConfig":
        return { feeReceiver: a.feeReceiver, liquidityFee: a.liquidityFeeBps, irStrategy: c.rateStrategy, reinvestmentController: ZERO };
      case "getSpokeCount":
        return BigInt(a.slices.length);
      case "getSpokeAddress":
        return a.slices[Number(args[1])]!.spoke;
      case "getSpoke": {
        const x = slice(args[1]);
        return { drawnShares: x.owed, premiumShares: 0n, premiumOffsetRay: 0n, addedShares: x.added, addCap: x.addCap, drawCap: x.drawCap, riskPremiumThreshold: 0, active: x.active ?? true, halted: false, deficitRay: 0n };
      }
      case "getSpokeAddedAssets":
        return slice(args[1]).added;
      case "getSpokeTotalOwed":
        return slice(args[1]).owed;
      case "getAddedAssets":
      case "getAddedShares":
        return added;
      case "getAssetOwed":
        return [a.drawn, a.premium];
      case "getAssetLiquidity":
        return a.liquidity;
      case "getAssetDeficitRay":
      case "getAssetAccruedFees":
        return 0n;
      case "getAssetDrawnRate":
        return a.drawnRateRay;
      case "getAssetDrawnIndex":
        return RAY;
    }
  }
  const lend = c.lendSpokes.find((l) => l.spoke === at);
  if (lend) {
    switch (fn) {
      case "getReserveCount":
        return BigInt(lend.reserves.length);
      case "ORACLE":
        return lend.oracle;
      case "getReserve": {
        const r = lend.reserves[Number(args[0])]!;
        const a = c.hubs.find((h) => h.hub === r.hub)!.assets[r.assetId]!;
        return { underlying: a.underlying, hub: r.hub, assetId: r.assetId, decimals: a.decimals, collateralRisk: 0, flags: 0, dynamicConfigKey: 0 };
      }
      case "getReserveConfig":
        return { collateralRisk: 0, paused: false, frozen: lend.reserves[Number(args[0])]!.frozen ?? false, borrowable: false, receiveSharesEnabled: false };
    }
  }
  const oracle = c.lendSpokes.find((l) => l.oracle === at);
  if (oracle) {
    if (fn === "decimals") return oracle.oracleDecimals;
    if (fn === "getReservePrice") return oracle.reserves[Number(args[0])]!.price;
  }
  const cdp = c.cdpSpokes.find((s) => s.spoke === at);
  if (cdp) {
    if (fn === "getLiquidationConfig") return { targetHealthFactor: 11n * 10n ** 17n, healthFactorForMaxBonus: 95n * 10n ** 16n, liquidationBonusFactor: 5_000 };
    if (fn === "getReserve") return { underlying: ZERO, hub: cdp.homeHub, assetId: 0, decimals: 18, collateralRisk: 500, flags: 0, dynamicConfigKey: 0 };
  }
  const offset = c.hubs.flatMap((h) => h.assets.flatMap((a) => a.slices)).find((x) => x.spoke === at && x.firstLossLayer);
  if (offset && fn === "FIRST_LOSS_LAYER") return offset.firstLossLayer;
  if (at === c.rateStrategy && fn === "getInterestRateData") return { optimalUsageRatio: 8_000, baseDrawnRate: 0, rateGrowthBeforeOptimal: 400, rateGrowthAfterOptimal: 6_000 };
  if (at === c.lens) {
    switch (fn) {
      case "LENS_MAX_PAGE":
        return 200n;
      case "getMarkets":
        return c.markets.slice(Number(args[0]), Number(args[0]) + Number(args[1]));
      case "getApplicationState":
        if (!c.recordedHubs.some((h) => eq(args[0], h))) throw new CallFailed("InvalidHub");
        return 0;
      case "getDebtReserves": {
        const s = c.cdpSpokes.find((x) => eq(args[0], x.spoke))!;
        return s.debtReserves.map((d) => ({ spoke: s.spoke, ...d, price: 10n ** 8n, fixedPrice: false, paused: false, frozen: false, borrowable: true, breakerReasons: 0, pauseState: 0 }));
      }
      case "getHubAssetExposure": {
        const h = c.hubs.find((x) => eq(args[0], x.hub))!;
        const a = h.assets.find((x) => eq(args[1], x.underlying));
        if (!a?.coverageSpoke) throw new CallFailed("NoCoverage");
        const cdpOf = (sp: Address) => c.cdpSpokes.find((s) => s.spoke === sp);
        const isOffset = (x: FakeSlice) => x.firstLossLayer === a.coverageSpoke;
        const kind = (x: FakeSlice) =>
          cdpOf(x.spoke) ? 1 : x.spoke === a.coverageSpoke ? 2 : x.spoke === a.feeReceiver ? 3 : isOffset(x) ? 5 : c.lendSpokes.some((l) => l.spoke === x.spoke) ? 0 : 4;
        const spokes = a.slices.map((x) => ({
          spoke: x.spoke,
          homeHub: cdpOf(x.spoke)?.homeHub ?? ZERO,
          drawCap: BigInt(x.drawCap),
          drawn: x.owed,
          deficit: 0n,
          kind: kind(x),
          added: x.added,
          addedShares: x.added,
          addCap: BigInt(x.addCap),
          drawnOwed: x.owed,
          premiumOwed: 0n,
          drawnShares: x.owed,
          premiumShares: 0n,
          active: x.active ?? true,
          halted: false,
        }));
        const offsets = a.slices.filter(isOffset);
        return {
          coverageSpoke: a.coverageSpoke,
          fundedBalance: a.slices.find((x) => x.spoke === a.coverageSpoke)?.added ?? 0n,
          line: 0n,
          coverageBoundHolds: true,
          uncovered: 0n,
          priceAdj: 10n ** 6n,
          spokes,
          deficitOffset: offsets[0]?.spoke ?? ZERO,
          offsetFunded: offsets.reduce((acc, x) => acc + x.added, 0n),
        };
      }
      case "getBorrowSpeed": {
        if (c.locked) throw new CallFailed("Locked");
        const m = c.markets.find((x) => x.marketId === args[0]);
        const r = c.cdpSpokes.find((x) => x.spoke === m?.spoke)?.debtReserves.find((x) => x.reserveId === args[1]);
        if (!m || !r) throw new CallFailed("UnknownDebtReserve");
        const unit = 10n ** BigInt(r.decimals);
        return {
          market: speedView(1_000_000n * 10n ** 8n, 250_000n * 10n ** 8n, SPEED_MORE_AT, 250_000n * 10n ** 8n),
          debt: speedView(500_000n * unit, 0n, 0, 0n),
          availableNow: 500_000n * unit,
          moreAt: BigInt(SPEED_MORE_AT),
        };
      }
      case "getPledgeSpeed":
        if (c.locked) throw new CallFailed("Locked");
        return speedView(2_500_000n * 10n ** 8n, 0n, 0, 0n);
    }
  }
  throw new CallFailed(`${fn} on ${at}`);
}

/** A multicall over the chain; every call reverting on chain comes back as a failure. */
export function fakeChainClient(chain: FakeChain): ViewClient & { readonly calls: ContractCall[] } {
  const calls: ContractCall[] = [];
  return {
    calls,
    async multicall(batch: readonly ContractCall[]): Promise<readonly CallResult[]> {
      calls.push(...batch);
      return batch.map((call) => {
        try {
          return { status: "success" as const, result: answer(chain, call) };
        } catch (error) {
          if (error instanceof CallFailed) return { status: "failure" as const, error };
          throw error;
        }
      });
    },
  };
}
