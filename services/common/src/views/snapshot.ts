// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads one chain's Hubs, their assets and Spoke slices, the Hub-to-Hub credit lines, the CDP debt reserves and the
// collateral markets at one block, for every Hub and Spoke discovery.ts finds.
// The indexer runs it at each hourly sample block (chart history) and Convex at the head (current values); both
// get the same rows from the same calls. Lens market, exposure and speed-limit views plus the Aave V4 Hub and Spoke
// views the Lens itself reads; appViews.ts holds the Lens views the app reads per account or Hub asset.

import { aaveOracleAbi, hubViewsAbi, lensViewsAbi, rateStrategyAbi, registryViewsAbi, spokeViewsAbi } from "./abi.ts";
import { type ContractCall, type ViewClient, ZERO, all, lower, s, some, uniq } from "./client.ts";
import { type HubAssetInfo, discover } from "./discovery.ts";
import { deficitFromRay, supplyRateRay, utilizationBps } from "./math.ts";
import type {
  Address,
  ChainDeployment,
  ChainSnapshot,
  CreditLineRow,
  HubAssetRow,
  HubAssetSpokeRow,
  HubRow,
  LendReserve,
  MarketBorrowRow,
  MarketRow,
  SpokeKind,
  SpeedWindow,
  SpokeReserveRow,
} from "./types.ts";

export type { CallResult, ContractCall, ViewClient } from "./client.ts";

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
interface DecodedExposure {
  coverageSpoke: Address;
  fundedBalance: bigint;
  line: bigint;
  coverageBoundHolds: boolean;
  uncovered: bigint;
  priceAdj: bigint;
  spokes: readonly { spoke: Address; homeHub: Address }[];
  deficitOffset: Address;
  offsetFunded: bigint;
}
interface DecodedSpeed {
  limit: bigint;
  used: bigint;
  available: bigint;
  moreAt: bigint | number;
  moreAmount: bigint;
  unavailable: boolean;
}
interface DecodedBorrowSpeed {
  market: DecodedSpeed;
  debt: DecodedSpeed;
  availableNow: bigint;
  moreAt: bigint | number;
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
  collateralRiskBps: bigint;
  liquidationFeeBps: bigint;
  targetHealthFactor: bigint;
  healthFactorForMaxBonus: bigint;
  liquidationBonusFactorBps: bigint;
  hardHealthFloor: bigint;
  marketUsdCap: bigint;
  topUpSliceUsd: bigint;
  depositorUsdCap: bigint;
  tokenUsdCaps: readonly bigint[];
  addCap: bigint;
  debtReserveIds: readonly bigint[];
  borrowRatesRay: readonly bigint[];
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

const reg = (registry: Address, functionName: string, args: readonly unknown[]): ContractCall => ({ address: registry, abi: registryViewsAbi, functionName, args });
const hubCall = (hub: Address, functionName: string, args: readonly unknown[]): ContractCall => ({ address: hub, abi: hubViewsAbi, functionName, args });
const spokeCall = (spoke: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: spoke, abi: spokeViewsAbi, functionName, args });
const speedRow = (v: DecodedSpeed): SpeedWindow => ({
  limit: s(v.limit),
  used: s(v.used),
  available: s(v.available),
  moreAt: Number(v.moreAt),
  moreAmount: s(v.moreAmount),
  unavailable: v.unavailable,
});

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
  const registry = lower(dep.marketRegistry);
  const topo = await discover(client, dep);
  const { cdpSpokes, lendSpokes } = topo;
  const L = lendSpokes.length;
  const C = cdpSpokes.length;

  // 1. Each Lend Spoke's reserve count and oracle, every CDP Spoke's debt reserves and liquidation config.
  const first = await all(client, [
    ...lendSpokes.flatMap((sp) => [spokeCall(sp, "getReserveCount"), spokeCall(sp, "ORACLE")]),
    ...cdpSpokes.map((sp): ContractCall => ({ address: lens, abi: lensViewsAbi, functionName: "getDebtReserves", args: [sp] })),
    ...cdpSpokes.map((sp) => spokeCall(sp, "getLiquidationConfig")),
  ]);
  const lendMeta = lendSpokes.map((spoke, i) => ({ spoke, count: Number(first[2 * i] as bigint), oracle: lower(first[2 * i + 1] as string) }));
  const debtReserves = (first.slice(2 * L, 2 * L + C) as DecodedDebtReserve[][]).flat();
  const liqConfigs = new Map(
    cdpSpokes.map((sp, i) => [sp, first[2 * L + C + i] as { targetHealthFactor: bigint; healthFactorForMaxBonus: bigint; liquidationBonusFactor: number }]),
  );
  const oracles = uniq(lendMeta.map((m) => m.oracle));

  // 2. Each oracle's decimals; each lend reserve's Hub asset, flags and price.
  const lendKeys = lendMeta.flatMap((m) => Array.from({ length: m.count }, (_, i) => ({ spoke: m.spoke, oracle: m.oracle, reserveId: BigInt(i) })));
  const lendReads = await all(client, [
    ...oracles.map((o): ContractCall => ({ address: o, abi: aaveOracleAbi, functionName: "decimals" })),
    ...lendKeys.flatMap((k) => [
      spokeCall(k.spoke, "getReserve", [k.reserveId]),
      spokeCall(k.spoke, "getReserveConfig", [k.reserveId]),
      { address: k.oracle, abi: aaveOracleAbi, functionName: "getReservePrice", args: [k.reserveId] },
    ]),
  ]);
  const O = oracles.length;
  const oracleDecimals = new Map(oracles.map((o, i) => [o, Number(lendReads[i] as number)]));
  const toUsd8 = (p: bigint, d: number): bigint => (d >= 8 ? p / 10n ** BigInt(d - 8) : p * 10n ** BigInt(8 - d));
  const infoOf = new Map(topo.assets.map((a) => [`${a.hub}:${a.assetId}`, a]));
  const grouped = new Map<string, { info: HubAssetInfo; reserves: LendReserve[]; priceUsd8: bigint }>();
  lendKeys.forEach((k, i) => {
    const reserve = lendReads[O + i * 3] as DecodedReserve;
    const config = lendReads[O + i * 3 + 1] as DecodedReserveConfig;
    const key = `${lower(reserve.hub)}:${BigInt(reserve.assetId)}`;
    const info = infoOf.get(key);
    if (!info) throw new Error(`Lend Spoke ${k.spoke} reserve ${k.reserveId} is on Hub ${lower(reserve.hub)}, which is neither in the manifest nor recorded by the MarketRegistry`);
    const entry = { spoke: k.spoke, reserveId: s(k.reserveId), paused: config.paused, frozen: config.frozen };
    const found = grouped.get(key);
    if (found) found.reserves.push(entry);
    else grouped.set(key, { info, reserves: [entry], priceUsd8: toUsd8(lendReads[O + i * 3 + 2] as bigint, oracleDecimals.get(k.oracle)!) });
  });
  const lendAssets = [...grouped.values()];

  // 3. Hub totals of each lend asset.
  const hubReads = await all(
    client,
    lendAssets.flatMap(({ info: a }) => [
      hubCall(a.hub, "getAddedAssets", [a.assetId]),
      hubCall(a.hub, "getAddedShares", [a.assetId]),
      hubCall(a.hub, "getAssetOwed", [a.assetId]),
      hubCall(a.hub, "getAssetLiquidity", [a.assetId]),
      hubCall(a.hub, "getAssetDeficitRay", [a.assetId]),
      hubCall(a.hub, "getAssetAccruedFees", [a.assetId]),
      hubCall(a.hub, "getAssetDrawnRate", [a.assetId]),
      hubCall(a.hub, "getAssetDrawnIndex", [a.assetId]),
    ]),
  );
  const PER_ASSET = 8;
  const totals = lendAssets.map((la, i) => {
    const r = hubReads.slice(i * PER_ASSET, (i + 1) * PER_ASSET);
    const [drawn, premium] = r[2] as [bigint, bigint];
    return {
      ...la,
      added: r[0] as bigint,
      addedShares: r[1] as bigint,
      drawn,
      premium,
      liquidity: r[3] as bigint,
      deficit: deficitFromRay(r[4] as bigint),
      accruedFees: r[5] as bigint,
      drawnRate: r[6] as bigint,
      drawnIndex: r[7] as bigint,
    };
  });

  // 4. Rate curves and the Lens exposure of each lend asset.
  const curves = await some(client, totals.map(({ info: a }) => ({ address: a.irStrategy, abi: rateStrategyAbi, functionName: "getInterestRateData", args: [a.assetId] })));
  const exposures = (await some(client, totals.map(({ info: a }) => ({ address: lens, abi: lensViewsAbi, functionName: "getHubAssetExposure", args: [a.hub, a.underlying] })))) as (DecodedExposure | null)[];

  // 5. Each slice's added and owed amounts; the registry cap of each Hub-to-Hub line.
  const lendSet = new Set(lendSpokes);
  const cdpSet = new Set(cdpSpokes);
  const sliceKeys = totals.flatMap((t, ti) =>
    t.info.spokes.map(({ spoke, data }) => {
      const exposure = exposures[ti];
      const homeHub = topo.homeHubOf.get(spoke) ?? lower(exposure?.spokes.find((x) => lower(x.spoke) === spoke)?.homeHub ?? ZERO);
      const kind: SpokeKind = lendSet.has(spoke)
        ? "lend"
        : cdpSet.has(spoke) || homeHub !== ZERO
          ? "cdp"
          : topo.coverage.has(spoke) || (exposure != null && lower(exposure.coverageSpoke) === spoke)
            ? "coverage"
            : t.info.deficitOffsets.includes(spoke)
              ? "deficitOffset"
              : spoke === t.info.feeReceiver
                ? "feeReceiver"
                : "other";
      return { t, spoke, data, homeHub, kind, crossHub: kind === "cdp" && homeHub !== ZERO && homeHub !== t.info.hub };
    }),
  );
  const lines = sliceKeys.filter((k) => k.crossHub);
  const lineAssets = uniq(lines.map((k) => k.t));
  const sliceReads = await all(client, [
    ...sliceKeys.flatMap(({ t, spoke }) => [hubCall(t.info.hub, "getSpokeAddedAssets", [t.info.assetId, spoke]), hubCall(t.info.hub, "getSpokeTotalOwed", [t.info.assetId, spoke])]),
    ...lines.map(({ t, spoke }) => reg(registry, "crossHubLineCap", [t.info.hub, t.info.underlying, spoke])),
    ...lineAssets.map((t) => reg(registry, "crossHubLineTotal", [t.info.hub, t.info.underlying])),
  ]);
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
  const S2 = sliceKeys.length * 2;
  const creditLines: CreditLineRow[] = lines.map(({ t, spoke, homeHub }, i) => ({
    chainId: dep.chainId,
    fundingHub: t.info.hub,
    assetId: s(t.info.assetId),
    asset: t.info.underlying,
    spoke,
    homeHub,
    cap: s(sliceReads[S2 + i] as bigint),
    total: s(sliceReads[S2 + lines.length + lineAssets.indexOf(t)] as bigint),
    enabled: topo.crossHubLinesEnabled,
    blockNumber: block,
  }));

  const hubAssets: HubAssetRow[] = totals.map((t, i) => {
    const a = t.info;
    const owed = t.drawn + t.premium;
    const curve = curves[i] as { optimalUsageRatio: number; baseDrawnRate: number; rateGrowthBeforeOptimal: number; rateGrowthAfterOptimal: number } | null;
    const exposure = exposures[i];
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
      exposure: exposure
        ? {
            coverageSpoke: lower(exposure.coverageSpoke),
            fundedBalance: s(exposure.fundedBalance),
            line: s(exposure.line),
            coverageBoundHolds: exposure.coverageBoundHolds,
            uncovered: s(exposure.uncovered),
            priceAdj: s(exposure.priceAdj),
            deficitOffset: lower(exposure.deficitOffset),
            offsetFunded: s(exposure.offsetFunded),
          }
        : null,
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
      recorded: h.recorded,
      applicationState: h.applicationState,
      assetCount: h.assetCount,
      lendAssetIds: mine.map((a) => a.assetId),
      lendSpokes: uniq(mine.flatMap((a) => a.lendReserves.map((r) => r.spoke))),
      cdpSpokes: cdpSpokes.filter((sp) => topo.homeHubOf.get(sp) === h.hub),
      blockNumber: block,
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

  // 6. Markets, the collateral risk of each vault-token reserve, and each market's borrow speed per debt reserve and
  // pledge speed (the Lens refuses both while the Lock is held).
  const decoded = await readMarkets(client, lens);
  const marketReads = await all(
    client,
    decoded.flatMap((m) => [spokeCall(lower(m.spoke), "getReserve", [m.reserveId]), hubCall(lower(m.hub), "getAssetUnderlyingAndDecimals", [m.hubAssetId])]),
  );
  const borrowKeys = decoded.flatMap((m, mi) => m.debtReserveIds.map((reserveId, ri) => ({ mi, reserveId, rateRay: m.borrowRatesRay[ri] ?? 0n, marketId: m.marketId })));
  const speeds = await some(client, [
    ...borrowKeys.map((k): ContractCall => ({ address: lens, abi: lensViewsAbi, functionName: "getBorrowSpeed", args: [k.marketId, k.reserveId] })),
    ...decoded.map((m): ContractCall => ({ address: lens, abi: lensViewsAbi, functionName: "getPledgeSpeed", args: [m.marketId] })),
  ]);
  const borrowOf = (mi: number): MarketBorrowRow[] =>
    borrowKeys.flatMap((k, j) => {
      if (k.mi !== mi) return [];
      const v = speeds[j] as DecodedBorrowSpeed | null;
      return [
        {
          reserveId: s(k.reserveId),
          borrowRateRay: s(k.rateRay),
          speed: v ? { availableNow: s(v.availableNow), moreAt: Number(v.moreAt), market: speedRow(v.market), debt: speedRow(v.debt) } : null,
        },
      ];
    });
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
      borrow: borrowOf(i),
      pledgeSpeed: speeds[borrowKeys.length + i] ? speedRow(speeds[borrowKeys.length + i] as DecodedSpeed) : null,
      blockNumber: block,
    };
  });

  return { chainId: dep.chainId, blockNumber: block, timestamp: at.timestamp, hubs, creditLines, hubAssets, slices, spokeReserves, markets };
}

