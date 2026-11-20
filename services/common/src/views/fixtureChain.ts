// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test data only: an in-memory chain that answers the snapshot reader's view calls the way the contracts do, so the
// tests run the real reader (snapshot.ts, discovery.ts) end to end. It holds Hubs with their assets and Spokes, Lend
// Spokes with their oracles, CDP Spokes with their oracles and debt reserves, the markets (the RiskModule's records,
// their LPOracles and vault-token reserves), the RiskModule's draw-cap coverage and the First-Loss Reserves' balances.
// A call to an address or function the chain does not hold fails, as it reverts on chain.

import type { CallResult, ContractCall, ViewClient } from "./client.ts";
import type { Address } from "./types.ts";

export interface FakeSlice {
  readonly spoke: Address;
  readonly added: bigint;
  readonly owed: bigint;
  readonly addCap: number;
  readonly drawCap: number;
  readonly active?: boolean;
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
  /** The First-Loss Reserve of (Hub, asset): a Spoke of the asset whose added amount is its funded balance. */
  readonly firstLossReserve?: Address;
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
  /** The Spoke's AaveOracle (8 decimals): debt reserves at their `price`, a vault token at its market's price. */
  readonly oracle: Address;
  readonly debtReserves: readonly {
    readonly reserveId: bigint;
    readonly hub: Address;
    readonly hubAssetId: bigint;
    readonly asset: Address;
    readonly decimals: number;
    readonly price?: bigint;
  }[];
}

/** One market as the RiskModule records it, with its vault-token reserve on its CDP Spoke and its LPOracle's price. */
export interface FakeMarket {
  readonly marketId: bigint;
  /** `IRiskModule.MarketKind`: 0 Full range, 1 Custom range. */
  readonly kind: 0 | 1;
  readonly pool: `0x${string}`;
  readonly spoke: Address;
  readonly hub: Address;
  readonly hubAssetId: bigint;
  readonly vaultToken: Address;
  readonly lpOracle: Address;
  readonly reserveId: bigint;
  readonly bandLower: number;
  readonly bandUpper: number;
  readonly ltvBps: number;
  readonly active: boolean;
  readonly frozen?: boolean;
  /** USD, 8 decimals, per whole vault token. */
  readonly price: bigint;
  readonly collateralRiskBps: number;
}

export interface FakeChain {
  readonly riskModule: Address;
  readonly rateStrategy: Address;
  readonly hubs: readonly FakeHub[];
  readonly lendSpokes: readonly FakeLendSpoke[];
  readonly cdpSpokes: readonly FakeCdpSpoke[];
  readonly markets: readonly FakeMarket[];
}

const ZERO: Address = "0x0000000000000000000000000000000000000000";
const eq = (a: unknown, b: string) => String(a).toLowerCase() === b.toLowerCase();

class CallFailed extends Error {}

/** The coverage ratio of the fake RiskModule: 5 %. */
export const FAKE_COVERAGE_RATIO_BPS = 500n;
const MAX_SPOKE_CAP = 2n ** 40n - 1n;

/**
 * `RiskModule.coverage(hub, asset)`: the live draw caps of every CDP Spoke with a debt reserve of the asset on the Hub
 * (an unbounded cap counts 2^128), the balance they require at `FAKE_COVERAGE_RATIO_BPS` and the First-Loss Reserve's
 * funded balance.
 */
function coverage(c: FakeChain, hub: unknown, asset: unknown): { drawCapSum: bigint; required: bigint; funded: bigint } {
  const h = c.hubs.find((x) => eq(hub, x.hub));
  const a = h?.assets.find((x) => eq(asset, x.underlying));
  if (!a) return { drawCapSum: 0n, required: 0n, funded: 0n };
  const spokes = c.cdpSpokes.filter((s) => s.debtReserves.some((r) => eq(hub, r.hub) && eq(asset, r.asset)));
  const drawCapSum = spokes.reduce((acc, s) => {
    const cap = BigInt(a.slices.find((x) => x.spoke === s.spoke)?.drawCap ?? 0);
    return acc + (cap === MAX_SPOKE_CAP ? 2n ** 128n : cap);
  }, 0n);
  const needed = drawCapSum * 10n ** BigInt(a.decimals) * FAKE_COVERAGE_RATIO_BPS;
  const required = (needed + 9_999n) / 10_000n;
  return { drawCapSum, required, funded: fundedOf(c, a) };
}

const fundedOf = (_c: FakeChain, a: FakeAsset) => (a.firstLossReserve ? (a.slices.find((x) => x.spoke === a.firstLossReserve)?.added ?? 0n) : 0n);

/** The view the chain answers for one call; throws `CallFailed` when the contract would refuse the call. */
function answer(c: FakeChain, call: ContractCall): unknown {
  const at = call.address.toLowerCase();
  const args = call.args ?? [];
  const fn = call.functionName;
  if (at === c.riskModule) {
    if (fn === "coverage") {
      const cov = coverage(c, args[0], args[1]);
      return [cov.drawCapSum, cov.required, cov.funded];
    }
    if (fn === "getMarket") {
      const m = c.markets.find((x) => x.marketId === args[0]);
      if (!m) throw new CallFailed("MarketNotListed");
      return {
        pool: m.pool, spoke: m.spoke, vaultToken: m.vaultToken, lpOracle: m.lpOracle, reserveId: m.reserveId, feedsHash: `0x${"00".repeat(32)}`,
        bandLower: m.bandLower, bandUpper: m.bandUpper, ltvBps: m.ltvBps, unitDecimals: 18, kind: m.kind, active: m.active,
      };
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
        return 10n ** 27n;
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
    const debt = cdp.debtReserves.find((r) => r.reserveId === args[0]);
    const collateral = c.markets.find((m) => m.spoke === cdp.spoke && m.reserveId === args[0]);
    switch (fn) {
      case "ORACLE":
        return cdp.oracle;
      case "getLiquidationConfig":
        return { targetHealthFactor: 11n * 10n ** 17n, healthFactorForMaxBonus: 95n * 10n ** 16n, liquidationBonusFactor: 5_000 };
      case "getReserve":
        if (debt) return { underlying: debt.asset, hub: debt.hub, assetId: Number(debt.hubAssetId), decimals: debt.decimals, collateralRisk: 0, flags: 0, dynamicConfigKey: 0 };
        if (collateral) return { underlying: collateral.vaultToken, hub: collateral.hub, assetId: Number(collateral.hubAssetId), decimals: 18, collateralRisk: collateral.collateralRiskBps, flags: 0, dynamicConfigKey: 1 };
        throw new CallFailed("ReserveNotListed");
      case "getReserveConfig":
        if (debt) return { collateralRisk: 0, paused: false, frozen: false, borrowable: true, receiveSharesEnabled: false };
        if (collateral) return { collateralRisk: collateral.collateralRiskBps, paused: false, frozen: collateral.frozen ?? false, borrowable: false, receiveSharesEnabled: false };
        throw new CallFailed("ReserveNotListed");
      case "getDynamicReserveConfig":
        if (!collateral) throw new CallFailed("ReserveNotListed");
        return { collateralFactor: collateral.ltvBps, maxLiquidationBonus: 10_500, liquidationFee: 1_000 };
    }
  }
  const cdpOracle = c.cdpSpokes.find((s) => s.oracle === at);
  if (cdpOracle) {
    if (fn === "decimals") return 8;
    if (fn === "getReservePrice") {
      const r = cdpOracle.debtReserves.find((x) => x.reserveId === args[0]);
      if (r) return r.price ?? 10n ** 8n;
      const m = c.markets.find((x) => x.spoke === cdpOracle.spoke && x.reserveId === args[0]);
      if (m) return m.price;
    }
  }
  const lpOracle = c.markets.find((m) => m.lpOracle === at);
  if (lpOracle) {
    if (fn === "latestAnswer") return lpOracle.price;
    if (fn === "decimals") return 8;
  }
  const vault = c.markets.find((m) => m.vaultToken === at);
  if (vault && fn === "symbol") return `av-${vault.marketId}`;
  const token = c.hubs.flatMap((h) => h.assets).find((a) => a.underlying === at);
  if (token && fn === "decimals") return token.decimals;
  const layer = c.hubs.flatMap((h) => h.assets).find((a) => a.firstLossReserve === at);
  if (layer && fn === "fundedBalance") return fundedOf(c, layer);
  if (at === c.rateStrategy && fn === "getInterestRateData") return { optimalUsageRatio: 8_000, baseDrawnRate: 0, rateGrowthBeforeOptimal: 400, rateGrowthAfterOptimal: 6_000 };
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
