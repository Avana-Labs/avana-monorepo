// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads one chain's Hub assets, their Spoke slices, the CDP debt reserves and the collateral markets at one block.
// The indexer runs it at each hourly sample block (chart history) and Convex at the head (current values); both
// get the same rows from the same calls. Round-1 Lens views plus the Aave V4 Hub and Spoke views the Lens itself
// reads; round2.ts lists the Lens views planned to replace the direct Hub reads.

import type { DecimalString } from "../export.ts";
import { aaveOracleAbi, hubViewsAbi, lensViewsAbi, rateStrategyAbi, spokeViewsAbi } from "./abi.ts";
import { deficitFromRay, supplyRateRay, utilizationBps } from "./math.ts";
import type {
  Address,
  ChainDeployment,
  ChainSnapshot,
  HubAssetRow,
  HubAssetSpokeRow,
  MarketRow,
  SpokeKind,
  SpokeReserveRow,
} from "./types.ts";

export interface ContractCall {
  readonly address: Address;
  readonly abi: readonly unknown[];
  readonly functionName: string;
  readonly args?: readonly unknown[];
}

export type CallResult = { readonly status: "success"; readonly result: unknown } | { readonly status: "failure"; readonly error: unknown };

/**
 * A multicall pinned to one block. The indexer wraps Ponder's `context.client` (pinned to the sample block), Convex
 * a viem client with `blockNumber`.
 */
export interface ViewClient {
  multicall(calls: readonly ContractCall[]): Promise<readonly CallResult[]>;
}

const ZERO: Address = "0x0000000000000000000000000000000000000000";
const s = (x: bigint | number): DecimalString => x.toString(10);
const lower = (a: string): Address => a.toLowerCase() as Address;

/** Runs calls that must all succeed; one failure fails the snapshot (no partial pages of numbers). */
async function all(client: ViewClient, calls: readonly ContractCall[]): Promise<unknown[]> {
  if (calls.length === 0) return [];
  const out = await client.multicall(calls);
  return out.map((r, i) => {
    if (r.status !== "success") throw new Error(`${calls[i]!.functionName} on ${calls[i]!.address} reverted: ${String(r.error)}`);
    return r.result;
  });
}

/** Runs calls that may revert (a Lens view that refuses an asset); a failure is null. */
async function some(client: ViewClient, calls: readonly ContractCall[]): Promise<unknown[]> {
  if (calls.length === 0) return [];
  return (await client.multicall(calls)).map((r) => (r.status === "success" ? r.result : null));
}

interface DecodedReserve {
  underlying: Address;
  hub: Address;
  assetId: number;
  decimals: number;
  collateralRisk: number;
}
interface DecodedReserveConfig {
  paused: boolean;
  frozen: boolean;
}
interface DecodedSpokeData {
  drawnShares: bigint;
  premiumShares: bigint;
  addedShares: bigint;
  addCap: number | bigint;
  drawCap: number | bigint;
  active: boolean;
  halted: boolean;
  deficitRay: bigint;
}
interface DecodedExposure {
  coverageSpoke: Address;
  fundedBalance: bigint;
  line: bigint;
  coverageBoundHolds: boolean;
  uncovered: bigint;
  priceAdj: bigint;
  spokes: readonly { spoke: Address; homeHub: Address }[];
}
interface DecodedMarket {
  marketId: bigint;
  status: number;
  pool: Address;
  poolId: `0x${string}`;
  tokens: readonly Address[];
  tokenDecimals: readonly number[];
  feeTier: number;
  tickLower: number;
  tickUpper: number;
  integrationId: number;
  ammProtocol: `0x${string}`;
  vaultToken: Address;
  name: string;
  symbol: string;
  lpOracle: Address;
  hub: Address;
  spoke: Address;
  reserveId: bigint;
  hubAssetId: bigint;
  acceptedPrice: bigint;
  priceState: number;
  suppliedUnits: bigint;
  suppliedUsd: bigint;
  collateralFactorBps: bigint;
  maxLiquidationBonusBps: bigint;
  marketHeadroomUsd: bigint;
  sliceHeadroomUsd: bigint;
  addHeadroom: bigint;
  pauseState: number;
  breakerReasons: number;
}
interface DecodedDebtReserve {
  spoke: Address;
  reserveId: bigint;
  asset: Address;
  decimals: number;
  price: bigint;
  fixedPrice: boolean;
  hub: Address;
  hubAssetId: bigint;
  paused: boolean;
  frozen: boolean;
  borrowable: boolean;
  breakerReasons: number;
  pauseState: number;
}

const hubCall = (hub: Address, functionName: string, args: readonly unknown[]): ContractCall => ({ address: hub, abi: hubViewsAbi, functionName, args });
const spokeCall = (spoke: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: spoke, abi: spokeViewsAbi, functionName, args });

/** Every market, page by page, until a short page. */
async function readMarkets(client: ViewClient, lens: Address): Promise<DecodedMarket[]> {
  const [maxPage] = (await all(client, [{ address: lens, abi: lensViewsAbi, functionName: "LENS_MAX_PAGE" }])) as [bigint];
  const out: DecodedMarket[] = [];
  for (let offset = 0n; ; offset += maxPage) {
    const [page] = (await all(client, [{ address: lens, abi: lensViewsAbi, functionName: "getMarkets", args: [offset, maxPage] }])) as [DecodedMarket[]];
    out.push(...page);
    if (BigInt(page.length) < maxPage) return out;
  }
}

/**
 * Reads the snapshot. `at` is the block the client is pinned to; it is written on every row so a consumer can
 * refuse to combine rows of different blocks.
 */
export async function readChainSnapshot(client: ViewClient, dep: ChainDeployment, at: { blockNumber: bigint; timestamp: number }): Promise<ChainSnapshot> {
  const block = s(at.blockNumber);
  const lens = lower(dep.lens);
  const lendSpoke = lower(dep.lendSpoke);
  const cdpSpokes = dep.cdpSpokes.map(lower);

  // 1. Lend reserves, the Lend Spoke's oracle, every CDP Spoke's debt reserves and liquidation config.
  const [reserveCount, oracle, ...rest] = await all(client, [
    spokeCall(lendSpoke, "getReserveCount"),
    spokeCall(lendSpoke, "ORACLE"),
    ...cdpSpokes.map((sp) => ({ address: lens, abi: lensViewsAbi, functionName: "getDebtReserves", args: [sp] })),
    ...cdpSpokes.map((sp) => spokeCall(sp, "getLiquidationConfig")),
  ]);
  const debtReserves = (rest.slice(0, cdpSpokes.length) as DecodedDebtReserve[][]).flat();
  const liqConfigs = new Map(
    cdpSpokes.map((sp, i) => [sp, rest[cdpSpokes.length + i] as { targetHealthFactor: bigint; healthFactorForMaxBonus: bigint; liquidationBonusFactor: number }]),
  );
  const lendIds = Array.from({ length: Number(reserveCount as bigint) }, (_, i) => BigInt(i));

  // 2. Each lend reserve's Hub asset, flags and oracle price.
  const lendReads = await all(client, [
    { address: lower(oracle as string), abi: aaveOracleAbi, functionName: "DECIMALS" },
    ...lendIds.flatMap((id) => [
      spokeCall(lendSpoke, "getReserve", [id]),
      spokeCall(lendSpoke, "getReserveConfig", [id]),
      { address: lower(oracle as string), abi: aaveOracleAbi, functionName: "getReservePrice", args: [id] },
    ]),
  ]);
  const oracleDecimals = Number(lendReads[0] as number);
  const toUsd8 = (p: bigint): bigint => (oracleDecimals >= 8 ? p / 10n ** BigInt(oracleDecimals - 8) : p * 10n ** BigInt(8 - oracleDecimals));
  const lendAssets = lendIds.map((id, i) => {
    const reserve = lendReads[1 + i * 3] as DecodedReserve;
    const config = lendReads[2 + i * 3] as DecodedReserveConfig;
    return { reserveId: id, hub: lower(reserve.hub), assetId: BigInt(reserve.assetId), underlying: lower(reserve.underlying), decimals: reserve.decimals, config, priceUsd8: toUsd8(lendReads[3 + i * 3] as bigint) };
  });

  // 3. Hub totals of each lend asset and the list of its Spokes.
  const hubReads = await all(
    client,
    lendAssets.flatMap((a) => [
      hubCall(a.hub, "getAddedAssets", [a.assetId]),
      hubCall(a.hub, "getAddedShares", [a.assetId]),
      hubCall(a.hub, "getAssetOwed", [a.assetId]),
      hubCall(a.hub, "getAssetLiquidity", [a.assetId]),
      hubCall(a.hub, "getAssetDeficitRay", [a.assetId]),
      hubCall(a.hub, "getAssetAccruedFees", [a.assetId]),
      hubCall(a.hub, "getAssetDrawnRate", [a.assetId]),
      hubCall(a.hub, "getAssetDrawnIndex", [a.assetId]),
      hubCall(a.hub, "getAssetConfig", [a.assetId]),
      hubCall(a.hub, "getSpokeCount", [a.assetId]),
    ]),
  );
  const PER_ASSET = 10;
  const totals = lendAssets.map((a, i) => {
    const r = hubReads.slice(i * PER_ASSET, (i + 1) * PER_ASSET);
    const [drawn, premium] = r[2] as [bigint, bigint];
    const config = r[8] as { feeReceiver: Address; liquidityFee: number; irStrategy: Address };
    return {
      ...a,
      added: r[0] as bigint,
      addedShares: r[1] as bigint,
      drawn,
      premium,
      liquidity: r[3] as bigint,
      deficit: deficitFromRay(r[4] as bigint),
      accruedFees: r[5] as bigint,
      drawnRate: r[6] as bigint,
      drawnIndex: r[7] as bigint,
      feeReceiver: lower(config.feeReceiver),
      liquidityFeeBps: Number(config.liquidityFee),
      irStrategy: lower(config.irStrategy),
      spokeCount: Number(r[9] as bigint),
    };
  });

  // 4. Spoke addresses, rate curves and the Lens exposure of each asset.
  const addrCalls = totals.flatMap((t) => Array.from({ length: t.spokeCount }, (_, j) => hubCall(t.hub, "getSpokeAddress", [t.assetId, BigInt(j)])));
  const spokeAddrs = (await all(client, addrCalls)).map((a) => lower(a as string));
  const curves = await some(client, totals.map((t) => ({ address: t.irStrategy, abi: rateStrategyAbi, functionName: "getInterestRateData", args: [t.assetId] })));
  const exposures = (await some(client, totals.map((t) => ({ address: lens, abi: lensViewsAbi, functionName: "getHubAssetExposure", args: [t.hub, t.underlying] })))) as (DecodedExposure | null)[];

  // 5. Each slice.
  let cursor = 0;
  const sliceKeys = totals.flatMap((t) => spokeAddrs.slice(cursor, (cursor += t.spokeCount)).map((spoke) => ({ t, spoke })));
  const sliceReads = await all(
    client,
    sliceKeys.flatMap(({ t, spoke }) => [
      hubCall(t.hub, "getSpoke", [t.assetId, spoke]),
      hubCall(t.hub, "getSpokeAddedAssets", [t.assetId, spoke]),
      hubCall(t.hub, "getSpokeTotalOwed", [t.assetId, spoke]),
    ]),
  );
  const coverage = new Set(dep.coverageSpokes.map((c) => lower(c.address)));
  const slices: HubAssetSpokeRow[] = sliceKeys.map(({ t, spoke }, i) => {
    const data = sliceReads[i * 3] as DecodedSpokeData;
    const exposure = exposures[totals.indexOf(t)];
    const homeHub = exposure?.spokes.find((x) => lower(x.spoke) === spoke)?.homeHub ?? ZERO;
    const kind: SpokeKind =
      spoke === lendSpoke
        ? "lend"
        : cdpSpokes.includes(spoke) || homeHub !== ZERO
          ? "cdp"
          : coverage.has(spoke) || (exposure !== null && exposure !== undefined && lower(exposure.coverageSpoke) === spoke)
            ? "coverage"
            : spoke === t.feeReceiver
              ? "feeReceiver"
              : "other";
    return {
      chainId: dep.chainId,
      hub: t.hub,
      assetId: s(t.assetId),
      spoke,
      kind,
      homeHub: lower(homeHub),
      added: s(sliceReads[i * 3 + 1] as bigint),
      addedShares: s(data.addedShares),
      owed: s(sliceReads[i * 3 + 2] as bigint),
      drawnShares: s(data.drawnShares),
      premiumShares: s(data.premiumShares),
      deficit: s(deficitFromRay(data.deficitRay)),
      addCap: s(BigInt(data.addCap)),
      drawCap: s(BigInt(data.drawCap)),
      active: data.active,
      halted: data.halted,
      blockNumber: block,
    };
  });

  const hubAssets: HubAssetRow[] = totals.map((t, i) => {
    const owed = t.drawn + t.premium;
    const curve = curves[i] as { optimalUsageRatio: number; baseDrawnRate: number; rateGrowthBeforeOptimal: number; rateGrowthAfterOptimal: number } | null;
    const exposure = exposures[i];
    return {
      chainId: dep.chainId,
      hub: t.hub,
      assetId: s(t.assetId),
      underlying: t.underlying,
      decimals: t.decimals,
      priceUsd8: s(t.priceUsd8),
      added: s(t.added),
      addedShares: s(t.addedShares),
      drawn: s(t.drawn),
      premium: s(t.premium),
      owed: s(owed),
      liquidity: s(t.liquidity),
      deficit: s(t.deficit),
      accruedFees: s(t.accruedFees),
      drawnIndexRay: s(t.drawnIndex),
      drawnRateRay: s(t.drawnRate),
      supplyRateRay: s(supplyRateRay(t.drawnRate, owed, t.added, t.liquidityFeeBps)),
      utilizationBps: utilizationBps(owed, t.added),
      liquidityFeeBps: t.liquidityFeeBps,
      feeReceiver: t.feeReceiver,
      rateCurve: curve
        ? {
            optimalUsageBps: Number(curve.optimalUsageRatio),
            baseDrawnRateBps: Number(curve.baseDrawnRate),
            rateGrowthBeforeOptimalBps: Number(curve.rateGrowthBeforeOptimal),
            rateGrowthAfterOptimalBps: Number(curve.rateGrowthAfterOptimal),
          }
        : null,
      lend: { spoke: lendSpoke, reserveId: s(t.reserveId), paused: t.config.paused, frozen: t.config.frozen },
      exposure: exposure
        ? {
            coverageSpoke: lower(exposure.coverageSpoke),
            fundedBalance: s(exposure.fundedBalance),
            line: s(exposure.line),
            coverageBoundHolds: exposure.coverageBoundHolds,
            uncovered: s(exposure.uncovered),
            priceAdj: s(exposure.priceAdj),
          }
        : null,
      blockNumber: block,
      timestamp: at.timestamp,
    };
  });

  const spokeReserves: SpokeReserveRow[] = debtReserves.map((d) => ({
    chainId: dep.chainId,
    spoke: lower(d.spoke),
    reserveId: s(d.reserveId),
    hub: lower(d.hub),
    assetId: s(d.hubAssetId),
    asset: lower(d.asset),
    decimals: Number(d.decimals),
    debtPrice: s(d.price),
    fixedPrice: d.fixedPrice,
    paused: d.paused,
    frozen: d.frozen,
    borrowable: d.borrowable,
    breakerReasons: Number(d.breakerReasons),
    pauseState: Number(d.pauseState),
    blockNumber: block,
  }));

  // 6. Markets and the collateral risk of each vault-token reserve.
  const decoded = await readMarkets(client, lens);
  const marketReads = await all(
    client,
    decoded.flatMap((m) => [spokeCall(lower(m.spoke), "getReserve", [m.reserveId]), hubCall(lower(m.hub), "getAssetUnderlyingAndDecimals", [m.hubAssetId])]),
  );
  const markets: MarketRow[] = decoded.map((m, i) => {
    const liq = liqConfigs.get(lower(m.spoke));
    return {
      chainId: dep.chainId,
      marketId: s(m.marketId),
      status: Number(m.status),
      pool: lower(m.pool),
      poolId: m.poolId,
      tokens: m.tokens.map(lower),
      tokenDecimals: m.tokenDecimals.map(Number),
      feeTier: Number(m.feeTier),
      tickLower: Number(m.tickLower),
      tickUpper: Number(m.tickUpper),
      integrationId: Number(m.integrationId),
      ammProtocol: m.ammProtocol,
      vaultToken: lower(m.vaultToken),
      vaultDecimals: Number((marketReads[i * 2 + 1] as [Address, number])[1]),
      name: m.name,
      symbol: m.symbol,
      lpOracle: lower(m.lpOracle),
      hub: lower(m.hub),
      spoke: lower(m.spoke),
      reserveId: s(m.reserveId),
      hubAssetId: s(m.hubAssetId),
      acceptedPrice: s(m.acceptedPrice),
      priceState: Number(m.priceState),
      suppliedUnits: s(m.suppliedUnits),
      suppliedUsd8: s(m.suppliedUsd),
      collateralFactorBps: Number(m.collateralFactorBps),
      maxLiquidationBonusBps: Number(m.maxLiquidationBonusBps),
      collateralRiskBps: Number((marketReads[i * 2] as DecodedReserve).collateralRisk),
      liquidation: liq
        ? {
            targetHealthFactorWad: s(liq.targetHealthFactor),
            healthFactorForMaxBonusWad: s(liq.healthFactorForMaxBonus),
            liquidationBonusFactorBps: Number(liq.liquidationBonusFactor),
          }
        : null,
      marketHeadroomUsd8: s(m.marketHeadroomUsd),
      sliceHeadroomUsd8: s(m.sliceHeadroomUsd),
      addHeadroom: s(m.addHeadroom),
      pauseState: Number(m.pauseState),
      breakerReasons: Number(m.breakerReasons),
      blockNumber: block,
    };
  });

  return { chainId: dep.chainId, blockNumber: block, timestamp: at.timestamp, hubAssets, slices, spokeReserves, markets };
}

