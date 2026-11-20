// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads one chain's Hubs, their assets and Spoke slices with their draw-cap coverage, the CDP debt reserves and the
// collateral markets (two per pool: Full range and Custom range) at one block, for every Hub and Spoke discovery.ts
// finds. The indexer runs it at each hourly sample block (chart history), Convex at the head (current values) and the
// monitor every round; all get the same rows from the same calls: the Aave V4 Hub and Spoke views, each market's
// RiskModule record and LPOracle, each RiskModule's draw-cap coverage and each First-Loss Reserve's balance.

import {
  aaveOracleAbi,
  erc20ViewsAbi,
  firstLossReserveViewsAbi,
  hubViewsAbi,
  lpOracleViewsAbi,
  rateStrategyAbi,
  riskModuleViewsAbi,
  spokeViewsAbi,
} from "./abi.ts";
import { type ContractCall, type ViewClient, ZERO, all, lower, s, some, uniq } from "./client.ts";
import { type HubAssetInfo, discover } from "./discovery.ts";
import { deficitFromRay, marketBorrowRateRay, supplyRateRay, utilizationBps } from "./math.ts";
import type {
  Address,
  ChainDeployment,
  ChainSnapshot,
  HubAssetRow,
  HubAssetSpokeRow,
  HubRow,
  LendReserve,
  MarketRow,
  SpokeKind,
  SpokeReserveRow,
} from "./types.ts";

export type { CallResult, ContractCall, ViewClient } from "./client.ts";

interface DecodedReserve {
  underlying: Address;
  hub: Address;
  assetId: number;
  decimals: number;
  collateralRisk: number;
  dynamicConfigKey: number;
}
interface DecodedReserveConfig {
  collateralRisk: number;
  paused: boolean;
  frozen: boolean;
  borrowable: boolean;
}
interface DecodedRiskMarket {
  pool: `0x${string}`;
  spoke: Address;
  vaultToken: Address;
  lpOracle: Address;
  reserveId: bigint;
  bandLower: number;
  bandUpper: number;
  ltvBps: number;
  unitDecimals: number;
  kind: number;
  active: boolean;
}

const hubCall = (hub: Address, functionName: string, args: readonly unknown[]): ContractCall => ({ address: hub, abi: hubViewsAbi, functionName, args });
const spokeCall = (spoke: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: spoke, abi: spokeViewsAbi, functionName, args });
const toUsd8 = (p: bigint, d: number): bigint => (d >= 8 ? p / 10n ** BigInt(d - 8) : p * 10n ** BigInt(8 - d));
const max0 = (x: bigint) => (x > 0n ? x : 0n);

/**
 * Reads the snapshot. `at` is the block the client is pinned to; it is written on every row so a consumer can
 * refuse to combine rows of different blocks.
 */
export async function readChainSnapshot(client: ViewClient, dep: ChainDeployment, at: { blockNumber: bigint; timestamp: number }): Promise<ChainSnapshot> {
  const block = s(at.blockNumber);
  const topo = await discover(client, dep);
  const { cdpSpokes, lendSpokes } = topo;
  const L = lendSpokes.length;
  const cdpSet = new Set(cdpSpokes);

  // 1. Each Lend Spoke's reserve count and oracle; each CDP Spoke's oracle and liquidation config.
  const first = await all(client, [
    ...lendSpokes.flatMap((sp) => [spokeCall(sp, "getReserveCount"), spokeCall(sp, "ORACLE")]),
    ...cdpSpokes.flatMap((sp) => [spokeCall(sp, "ORACLE"), spokeCall(sp, "getLiquidationConfig")]),
  ]);
  const lendMeta = lendSpokes.map((spoke, i) => ({ spoke, count: Number(first[2 * i] as bigint), oracle: lower(first[2 * i + 1] as string) }));
  const cdpOracle = new Map(cdpSpokes.map((sp, i) => [sp, lower(first[2 * L + 2 * i] as string)]));
  const liqConfigs = new Map(
    cdpSpokes.map((sp, i) => [sp, first[2 * L + 2 * i + 1] as { targetHealthFactor: bigint; healthFactorForMaxBonus: bigint; liquidationBonusFactor: number }]),
  );
  const debtKeys = dep.debtReserves.map((r) => ({ spoke: lower(r.spoke), reserveId: r.reserveId, fixedPrice: r.fixedPrice })).filter((r) => cdpSet.has(r.spoke));
  const oracles = uniq([...lendMeta.map((m) => m.oracle), ...debtKeys.map((k) => cdpOracle.get(k.spoke)!)]);

  // 2. Each oracle's decimals; each lend reserve's and debt reserve's Hub asset, flags and price.
  const lendKeys = lendMeta.flatMap((m) => Array.from({ length: m.count }, (_, i) => ({ spoke: m.spoke, oracle: m.oracle, reserveId: BigInt(i) })));
  const reserveKeys = [...lendKeys, ...debtKeys.map((k) => ({ ...k, oracle: cdpOracle.get(k.spoke)! }))];
  const reads = await all(client, [
    ...oracles.map((o): ContractCall => ({ address: o, abi: aaveOracleAbi, functionName: "decimals" })),
    ...reserveKeys.flatMap((k) => [
      spokeCall(k.spoke, "getReserve", [k.reserveId]),
      spokeCall(k.spoke, "getReserveConfig", [k.reserveId]),
      { address: k.oracle, abi: aaveOracleAbi, functionName: "getReservePrice", args: [k.reserveId] },
    ]),
  ]);
  const O = oracles.length;
  const oracleDecimals = new Map(oracles.map((o, i) => [o, Number(reads[i] as number)]));
  const reserveAt = (i: number) => ({
    reserve: reads[O + i * 3] as DecodedReserve,
    config: reads[O + i * 3 + 1] as DecodedReserveConfig,
    priceUsd8: toUsd8(reads[O + i * 3 + 2] as bigint, oracleDecimals.get(reserveKeys[i]!.oracle)!),
  });
  const infoOf = new Map(topo.assets.map((a) => [`${a.hub}:${a.assetId}`, a]));
  const grouped = new Map<string, { info: HubAssetInfo; reserves: LendReserve[]; priceUsd8: bigint }>();
  lendKeys.forEach((k, i) => {
    const { reserve, config, priceUsd8 } = reserveAt(i);
    const key = `${lower(reserve.hub)}:${BigInt(reserve.assetId)}`;
    const info = infoOf.get(key);
    if (!info) throw new Error(`Lend Spoke ${k.spoke} reserve ${k.reserveId} is on Hub ${lower(reserve.hub)}, which the manifest does not list`);
    const entry = { spoke: k.spoke, reserveId: s(k.reserveId), paused: config.paused, frozen: config.frozen };
    const found = grouped.get(key);
    if (found) found.reserves.push(entry);
    else grouped.set(key, { info, reserves: [entry], priceUsd8 });
  });
  const lendAssets = [...grouped.values()];
  const spokeReserves: SpokeReserveRow[] = debtKeys.map((k, j) => {
    const { reserve, config, priceUsd8 } = reserveAt(lendKeys.length + j);
    return {
      chainId: dep.chainId,
      spoke: k.spoke,
      reserveId: s(k.reserveId),
      hub: lower(reserve.hub),
      assetId: s(BigInt(reserve.assetId)),
      asset: lower(reserve.underlying),
      decimals: Number(reserve.decimals),
      debtPrice: s(priceUsd8),
      fixedPrice: k.fixedPrice,
      paused: config.paused,
      frozen: config.frozen,
      borrowable: config.borrowable,
      blockNumber: block,
    };
  });

  // 3. Hub totals of each lend asset.
  const TOTALS = ["getAddedAssets", "getAddedShares", "getAssetOwed", "getAssetLiquidity", "getAssetDeficitRay", "getAssetAccruedFees", "getAssetDrawnRate", "getAssetDrawnIndex"];
  const hubReads = await all(client, lendAssets.flatMap(({ info: a }) => TOTALS.map((fn) => hubCall(a.hub, fn, [a.assetId]))));
  const totals = lendAssets.map((la, i) => {
    const r = (k: number) => hubReads[i * TOTALS.length + k];
    const [drawn, premium] = r(2) as [bigint, bigint];
    return {
      ...la,
      added: r(0) as bigint,
      addedShares: r(1) as bigint,
      drawn,
      premium,
      liquidity: r(3) as bigint,
      deficit: deficitFromRay(r(4) as bigint),
      accruedFees: r(5) as bigint,
      drawnRate: r(6) as bigint,
      drawnIndex: r(7) as bigint,
    };
  });

  // 4. Rate curves, each First-Loss Reserve's balance and each RiskModule's draw-cap coverage of each lend asset.
  const covered = totals.map((t) => t.info.firstLossReserve !== ZERO);
  const curves = await some(client, totals.map(({ info: a }) => ({ address: a.irStrategy, abi: rateStrategyAbi, functionName: "getInterestRateData", args: [a.assetId] })));
  const R = dep.riskModules.length;
  const coverReads = await some(
    client,
    totals.flatMap(({ info: a }, i) =>
      covered[i]
        ? [
            { address: a.firstLossReserve, abi: firstLossReserveViewsAbi, functionName: "fundedBalance", args: [] } as ContractCall,
            ...dep.riskModules.map((rm): ContractCall => ({ address: lower(rm), abi: riskModuleViewsAbi, functionName: "coverage", args: [a.hub, a.underlying] })),
          ]
        : [],
    ),
  );

  // 5. Each slice's added and owed amounts.
  const lendSet = new Set(lendSpokes);
  const sliceKeys = totals.flatMap((t) =>
    t.info.spokes.map(({ spoke, data }) => {
      const homeHub = cdpSet.has(spoke) ? (topo.homeHubOf.get(spoke) ?? ZERO) : ZERO;
      const kind: SpokeKind = lendSet.has(spoke)
        ? "lend"
        : cdpSet.has(spoke)
          ? "cdp"
          : spoke === t.info.firstLossReserve
            ? "coverage"
            : t.info.deficitOffsets.includes(spoke)
              ? "deficitOffset"
              : spoke === t.info.feeReceiver
                ? "feeReceiver"
                : topo.coverage.has(spoke)
                  ? "coverage"
                  : "other";
      return { t, spoke, data, homeHub, kind };
    }),
  );
  const sliceReads = await all(
    client,
    sliceKeys.flatMap(({ t, spoke }) => [hubCall(t.info.hub, "getSpokeAddedAssets", [t.info.assetId, spoke]), hubCall(t.info.hub, "getSpokeTotalOwed", [t.info.assetId, spoke])]),
  );
  const slices: HubAssetSpokeRow[] = sliceKeys.map(({ t, spoke, data, homeHub, kind }, i) => ({
    chainId: dep.chainId,
    hub: t.info.hub,
    assetId: s(t.info.assetId),
    spoke,
    kind,
    homeHub,
    added: s(sliceReads[i * 2] as bigint),
    addedShares: s(data.addedShares),
    owed: s(sliceReads[i * 2 + 1] as bigint),
    drawnShares: s(data.drawnShares),
    premiumShares: s(data.premiumShares),
    deficit: s(deficitFromRay(data.deficitRay)),
    addCap: s(BigInt(data.addCap)),
    drawCap: s(BigInt(data.drawCap)),
    active: data.active,
    halted: data.halted,
    blockNumber: block,
  }));

  let coverCursor = 0;
  const hubAssets: HubAssetRow[] = totals.map((t, i) => {
    const a = t.info;
    const owed = t.drawn + t.premium;
    const curve = curves[i] as { optimalUsageRatio: number; baseDrawnRate: number; rateGrowthBeforeOptimal: number; rateGrowthAfterOptimal: number } | null;
    let exposure: HubAssetRow["exposure"] = null;
    if (covered[i]) {
      const funded = coverReads[coverCursor] as bigint | null;
      const perModule = coverReads.slice(coverCursor + 1, coverCursor + 1 + R) as (readonly [bigint, bigint, bigint] | null)[];
      coverCursor += 1 + R;
      if (funded !== null) {
        const drawCapSum = perModule.reduce((acc, c) => acc + (c?.[0] ?? 0n), 0n);
        const required = perModule.reduce((acc, c) => acc + (c?.[1] ?? 0n), 0n);
        const offset = a.deficitOffsets[0] ?? ZERO;
        const offsetFunded = slices.filter((x) => x.hub === a.hub && x.assetId === s(a.assetId) && a.deficitOffsets.includes(x.spoke)).reduce((acc, x) => acc + BigInt(x.added), 0n);
        exposure = {
          firstLossReserve: a.firstLossReserve,
          fundedBalance: s(funded),
          drawCapSum: s(drawCapSum),
          required: s(required),
          coverageBoundHolds: required <= funded,
          uncovered: s(max0(t.deficit - funded - offsetFunded)),
          deficitOffset: offset,
          offsetFunded: s(offsetFunded),
        };
      }
    }
    return {
      chainId: dep.chainId,
      hub: a.hub,
      assetId: s(a.assetId),
      underlying: a.underlying,
      decimals: a.decimals,
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
      supplyRateRay: s(supplyRateRay(t.drawnRate, owed, t.added, a.liquidityFeeBps)),
      utilizationBps: utilizationBps(owed, t.added),
      liquidityFeeBps: a.liquidityFeeBps,
      feeReceiver: a.feeReceiver,
      rateCurve: curve
        ? {
            optimalUsageBps: Number(curve.optimalUsageRatio),
            baseDrawnRateBps: Number(curve.baseDrawnRate),
            rateGrowthBeforeOptimalBps: Number(curve.rateGrowthBeforeOptimal),
            rateGrowthAfterOptimalBps: Number(curve.rateGrowthAfterOptimal),
          }
        : null,
      lend: t.reserves[0]!,
      lendReserves: t.reserves,
      exposure,
      blockNumber: block,
      timestamp: at.timestamp,
    };
  });

  const hubs: HubRow[] = topo.hubs.map((h) => {
    const mine = hubAssets.filter((a) => a.hub === h.hub);
    return {
      chainId: dep.chainId,
      hub: h.hub,
      label: h.label,
      tier: h.tier,
      assetCount: h.assetCount,
      lendAssetIds: mine.map((a) => a.assetId),
      lendSpokes: uniq(mine.flatMap((a) => a.lendReserves.map((r) => r.spoke))),
      cdpSpokes: cdpSpokes.filter((sp) => topo.homeHubOf.get(sp) === h.hub),
      blockNumber: block,
    };
  });

  // 6. Markets of a live CDP Spoke: the RiskModule's record, the LPOracle's price, the vault-token reserve and the
  // pool tokens' decimals; then the reserve's dynamic config and the Spoke's supplied units.
  const markets = dep.markets.filter((m) => cdpSet.has(lower(m.spoke)));
  const marketReads = await all(
    client,
    markets.flatMap((m): ContractCall[] => [
      { address: lower(m.riskModule), abi: riskModuleViewsAbi, functionName: "getMarket", args: [m.marketId] },
      { address: lower(m.lpOracle), abi: lpOracleViewsAbi, functionName: "latestAnswer", args: [] },
      { address: lower(m.lpOracle), abi: lpOracleViewsAbi, functionName: "decimals", args: [] },
      spokeCall(lower(m.spoke), "getReserve", [m.reserveId]),
      spokeCall(lower(m.spoke), "getReserveConfig", [m.reserveId]),
      { address: lower(m.vaultToken), abi: erc20ViewsAbi, functionName: "symbol", args: [] },
      ...m.tokens.map((t): ContractCall => ({ address: lower(t), abi: erc20ViewsAbi, functionName: "decimals", args: [] })),
    ]),
  );
  let mc = 0;
  const decoded = markets.map((m) => {
    const rm = marketReads[mc++] as DecodedRiskMarket;
    const price = marketReads[mc++] as bigint;
    const priceDecimals = Number(marketReads[mc++] as number);
    const reserve = marketReads[mc++] as DecodedReserve;
    const config = marketReads[mc++] as DecodedReserveConfig;
    const symbol = marketReads[mc++] as string;
    const tokenDecimals = m.tokens.map(() => Number(marketReads[mc++] as number));
    return { m, rm, price: toUsd8(price > 0n ? price : 0n, priceDecimals), reserve, config, symbol, tokenDecimals };
  });
  const second = await all(
    client,
    decoded.flatMap(({ m, reserve }) => [
      spokeCall(lower(m.spoke), "getDynamicReserveConfig", [m.reserveId, reserve.dynamicConfigKey]),
      hubCall(lower(reserve.hub), "getSpokeAddedAssets", [BigInt(reserve.assetId), lower(m.spoke)]),
    ]),
  );
  const rateOf = (hub: Address, asset: Address) => hubAssets.find((a) => a.hub === hub && a.underlying === asset)?.drawnRateRay ?? "0";
  const marketRows: MarketRow[] = decoded.map(({ m, rm, price, reserve, config, symbol, tokenDecimals }, i) => {
    const dyn = second[i * 2] as { collateralFactor: number; maxLiquidationBonus: number; liquidationFee: number };
    const supplied = second[i * 2 + 1] as bigint;
    const vaultDecimals = Number(reserve.decimals);
    const liq = liqConfigs.get(lower(m.spoke));
    return {
      chainId: dep.chainId,
      marketId: s(m.marketId),
      kind: rm.kind === 0 ? "full-range" : "custom-range",
      active: rm.active,
      pool: rm.pool.toLowerCase() as `0x${string}`,
      tokens: m.tokens.map(lower),
      tokenDecimals,
      bandLower: Number(rm.bandLower),
      bandUpper: Number(rm.bandUpper),
      integrationId: m.integrationId,
      vaultToken: lower(m.vaultToken),
      vaultDecimals,
      unitDecimals: Number(rm.unitDecimals),
      name: m.name,
      symbol,
      lpOracle: lower(m.lpOracle),
      hub: lower(reserve.hub),
      spoke: lower(m.spoke),
      reserveId: s(m.reserveId),
      hubAssetId: s(BigInt(reserve.assetId)),
      acceptedPrice: s(price),
      suppliedUnits: s(supplied),
      suppliedUsd8: s((supplied * price) / 10n ** BigInt(vaultDecimals)),
      ltvBps: Number(rm.ltvBps),
      collateralFactorBps: Number(dyn.collateralFactor),
      maxLiquidationBonusBps: Number(dyn.maxLiquidationBonus),
      liquidationFeeBps: Number(dyn.liquidationFee),
      collateralRiskBps: Number(reserve.collateralRisk),
      paused: config.paused,
      frozen: config.frozen,
      liquidation: liq
        ? {
            targetHealthFactorWad: s(liq.targetHealthFactor),
            healthFactorForMaxBonusWad: s(liq.healthFactorForMaxBonus),
            liquidationBonusFactorBps: Number(liq.liquidationBonusFactor),
          }
        : null,
      borrow: spokeReserves
        .filter((r) => r.spoke === lower(m.spoke))
        .map((r) => ({ reserveId: r.reserveId, borrowRateRay: s(marketBorrowRateRay(rateOf(r.hub, r.asset), Number(reserve.collateralRisk))) })),
      blockNumber: block,
    };
  });

  return { chainId: dep.chainId, blockNumber: block, timestamp: at.timestamp, hubs, hubAssets, slices, spokeReserves, markets: marketRows };
}
