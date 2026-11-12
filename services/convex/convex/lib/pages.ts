// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Builds each screen's numbers from the scope rows. The Lend row and the Hub block of a Borrow asset row read the
// same Hub asset row; a Borrow asset row adds only its own Spoke slice; a pool row reads its market and the debt
// the market backs. "Borrowed" is owed (drawn + premium) everywhere and "available" is the Hub's liquidity bounded
// by the Spoke's cap room, never supplied − borrowed. Every USD figure of an asset uses the Lend Spoke's price.

import {
  type HubAssetRow,
  type HubAssetSpokeRow,
  type MarketReserveDebtRow,
  type MarketRow,
  type SpokeReserveRow,
  bpsToPct,
  marketBorrowRateRay,
  rayToAprPct,
  rayToApyPct,
  spokeHeadroom,
  usd,
} from "@avana/services-common/views";
import { feeTierLabel } from "./format.ts";
import type { MarketSnapshotRow, PageContent, PoolBorrowable, AllocationRow, InterestRateModel } from "./uiTypes.ts";

export type WithSlug<T> = T & { readonly slug: string };

/** `chainId:hub:assetId`, the key a Hub asset is joined by. */
export const hubAssetKey = (r: { chainId: number; hub: string; assetId: string }) => `${r.chainId}:${r.hub}:${r.assetId}`;

const identity = (content: PageContent | null, fallback: { name: string; symbol: string }) => ({
  name: content?.name ?? fallback.name,
  symbol: content?.symbol ?? fallback.symbol,
  ...(content?.category ? { category: content.category } : {}),
  ...(content?.venueLabel ? { venueLabel: content.venueLabel } : {}),
  ...(content?.description ? { description: content.description } : {}),
  ...(content?.iconUrl ? { iconUrl: content.iconUrl } : {}),
  ...(content?.visuals ? { visuals: content.visuals } : {}),
  ...(content?.resources ? { resources: content.resources } : {}),
});

/** Lend list row and Lend page header: one Hub asset. */
export function lendSnapshot(asset: WithSlug<HubAssetRow>, content: PageContent | null, symbol: string): MarketSnapshotRow {
  const price = asset.priceUsd8;
  const suppliedUsd = usd(asset.added, asset.decimals, price);
  return {
    slug: asset.slug,
    scope: "lend",
    chainId: asset.chainId,
    ...identity(content, { name: symbol, symbol }),
    reserveFactorPct: bpsToPct(asset.liquidityFeeBps),
    suppliedUsd,
    borrowedUsd: usd(asset.owed, asset.decimals, price),
    availableUsd: usd(asset.liquidity, asset.decimals, price),
    utilizationPct: bpsToPct(asset.utilizationBps),
    supplyApyPct: rayToApyPct(asset.supplyRateRay),
    borrowAprPct: rayToAprPct(asset.drawnRateRay),
    tvlUsd: suppliedUsd,
    volumeUsd: 0,
    feesUsd: 0,
  };
}

/**
 * Borrow list row and Borrow asset page header: one CDP Spoke's debt reserve. Supplied, utilization and rates are
 * the Hub's (the same row the Lend page reads); borrowed is this Spoke's owed amount; available is this Spoke's
 * headroom `min(cap room, Hub liquidity)`.
 */
export function assetSnapshot(
  reserve: WithSlug<SpokeReserveRow>,
  slice: HubAssetSpokeRow,
  asset: HubAssetRow,
  content: PageContent | null,
  symbol: string,
  spokeSlug: string,
): MarketSnapshotRow {
  const price = asset.priceUsd8;
  const suppliedUsd = usd(asset.added, asset.decimals, price);
  return {
    slug: reserve.slug,
    scope: "asset",
    chainId: reserve.chainId,
    ...identity(content, { name: symbol, symbol }),
    spokeId: spokeSlug,
    reserveFactorPct: bpsToPct(asset.liquidityFeeBps),
    suppliedUsd,
    borrowedUsd: usd(slice.owed, asset.decimals, price),
    availableUsd: usd(spokeHeadroom(slice, asset), asset.decimals, price),
    utilizationPct: bpsToPct(asset.utilizationBps),
    supplyApyPct: rayToApyPct(asset.supplyRateRay),
    borrowAprPct: rayToAprPct(asset.drawnRateRay),
    tvlUsd: suppliedUsd,
    volumeUsd: 0,
    feesUsd: 0,
  };
}

/** USD value of the debt a market backs, each reserve at its Hub asset's Lend Spoke price. */
export function marketDebtUsd(debts: readonly MarketReserveDebtRow[], reserves: readonly SpokeReserveRow[], assets: ReadonlyMap<string, HubAssetRow>): number {
  let total = 0;
  for (const d of debts) {
    const r = reserves.find((x) => x.spoke === d.spoke && x.reserveId === d.reserveId);
    const a = r ? assets.get(hubAssetKey(r)) : undefined;
    if (a) total += usd(d.debt, a.decimals, a.priceUsd8);
  }
  return total;
}

/** The reserve a market's headline borrow rate is quoted on: the Spoke's first borrowable debt reserve. */
export function headlineReserve(reserves: readonly SpokeReserveRow[], spoke: string): SpokeReserveRow | undefined {
  return reserves.filter((r) => r.spoke === spoke && r.borrowable).sort((a, b) => Number(BigInt(a.reserveId) - BigInt(b.reserveId)))[0];
}

/**
 * Borrow list collateral row and pool page header: one market. Supplied is collateral value; borrowed is the debt
 * the market backs; available is the market's cap headroom; utilization is the loan-to-value of the market; the
 * borrow APR is this market's rate `drawnRate × (1 + collateralRisk)` on the Spoke's first debt reserve.
 */
export function poolSnapshot(
  market: WithSlug<MarketRow>,
  debts: readonly MarketReserveDebtRow[],
  reserves: readonly SpokeReserveRow[],
  assets: ReadonlyMap<string, HubAssetRow>,
  pool24h: { volumeUsd: number; feesUsd: number },
  content: PageContent | null,
): MarketSnapshotRow {
  const collateralUsd = Number(BigInt(market.suppliedUsd8)) / 1e8;
  const debtUsd = marketDebtUsd(debts, reserves, assets);
  const head = headlineReserve(reserves, market.spoke);
  const headAsset = head ? assets.get(hubAssetKey(head)) : undefined;
  return {
    slug: market.slug,
    scope: "pool",
    chainId: market.chainId,
    ...identity(content, { name: market.name, symbol: market.symbol }),
    spokeId: market.spoke,
    feeTier: feeTierLabel(market.feeTier),
    maxLtvPct: bpsToPct(market.collateralFactorBps),
    premiumBps: market.collateralRiskBps,
    suppliedUsd: collateralUsd,
    borrowedUsd: debtUsd,
    availableUsd: Number(BigInt(market.marketHeadroomUsd8)) / 1e8,
    utilizationPct: collateralUsd > 0 ? Math.min(100, (debtUsd / collateralUsd) * 100) : 0,
    // The LP fee APR needs the whole pool's in-range liquidity value, which no view reads yet (an external rate for now).
    supplyApyPct: 0,
    borrowAprPct: headAsset ? rayToAprPct(marketBorrowRateRay(headAsset.drawnRateRay, market.collateralRiskBps)) : 0,
    tvlUsd: collateralUsd,
    volumeUsd: pool24h.volumeUsd,
    feesUsd: pool24h.feesUsd,
    lpPriceUsd: Number(BigInt(market.acceptedPrice)) / 1e8,
  };
}

/** The rate curve card: Hub parameters and the current point, base rate only. */
export function interestRateModel(slug: string, asset: HubAssetRow): InterestRateModel | null {
  if (!asset.rateCurve) return null;
  return {
    slug,
    optimalUtilizationPct: bpsToPct(asset.rateCurve.optimalUsageBps),
    slopeBelowOptimalPct: bpsToPct(asset.rateCurve.rateGrowthBeforeOptimalBps),
    slopeAboveOptimalPct: bpsToPct(asset.rateCurve.rateGrowthAfterOptimalBps),
    baseBorrowRatePct: bpsToPct(asset.rateCurve.baseDrawnRateBps),
    utilizationPct: bpsToPct(asset.utilizationBps),
    borrowAprPct: rayToAprPct(asset.drawnRateRay),
    updatedAt: asset.timestamp * 1000,
    source: "chain",
  };
}

/** "Assets you can borrow" on a pool page: each debt reserve of the market's Spoke at this market's rate. */
export function poolBorrowables(
  market: MarketRow,
  reserves: readonly WithSlug<SpokeReserveRow>[],
  assets: ReadonlyMap<string, HubAssetRow>,
  symbolOf: (asset: string) => string,
): PoolBorrowable[] {
  return reserves
    .filter((r) => r.spoke === market.spoke && r.borrowable)
    .flatMap((r) => {
      const a = assets.get(hubAssetKey(r));
      if (!a) return [];
      const symbol = symbolOf(r.asset);
      return [{ id: r.slug, name: symbol, symbol, borrowAprPct: rayToAprPct(marketBorrowRateRay(a.drawnRateRay, market.collateralRiskBps)) }];
    })
    .sort((x, y) => x.name.localeCompare(y.name));
}

/**
 * "Collateral markets borrowing this asset" on a Borrow asset page: the Spoke's owed amount split by the market
 * whose accounts owe it. Shares are of the Σ over markets, which equals the Spoke's owed amount up to one unit per
 * account (each account rounds up).
 */
export function marketAllocation(
  reserve: SpokeReserveRow,
  asset: HubAssetRow,
  markets: readonly WithSlug<MarketRow>[],
  debts: readonly MarketReserveDebtRow[],
  contentOf: (marketSlug: string) => PageContent | null,
): AllocationRow[] {
  const mine = debts.filter((d) => d.spoke === reserve.spoke && d.reserveId === reserve.reserveId && BigInt(d.debt) > 0n);
  const total = mine.reduce((acc, d) => acc + BigInt(d.debt), 0n);
  return mine
    .flatMap((d) => {
      const m = markets.find((x) => x.chainId === d.chainId && x.marketId === d.marketId);
      if (!m) return [];
      const valueUsd = usd(d.debt, asset.decimals, asset.priceUsd8);
      const collateralUsd = Number(BigInt(m.suppliedUsd8)) / 1e8;
      const content = contentOf(m.slug);
      return [
        {
          id: `${m.chainId}:${m.marketId}`,
          poolSlug: m.slug,
          poolName: content?.name ?? m.name,
          venueLabel: content?.venueLabel ?? "",
          sharePct: total > 0n ? Number((BigInt(d.debt) * 1_000_000n) / total) / 10_000 : 0,
          valueUsd,
          utilizationPct: collateralUsd > 0 ? Math.min(100, (valueUsd / collateralUsd) * 100) : 0,
          borrowAprPct: rayToAprPct(marketBorrowRateRay(asset.drawnRateRay, m.collateralRiskBps)),
        },
      ];
    })
    .sort((a, b) => b.sharePct - a.sharePct);
}

/** Σ of a CDP Spoke's market rows, for the check that they reconcile to the Spoke's owed amount. */
export function sumMarketDebt(debts: readonly MarketReserveDebtRow[], spoke: string, reserveId: string): bigint {
  return debts.filter((d) => d.spoke === spoke && d.reserveId === reserveId).reduce((acc, d) => acc + BigInt(d.debt), 0n);
}

/** The Lend page's allocation by Spoke: every slice with its share of the Hub's owed and added amounts. */
export function spokeAllocation(asset: HubAssetRow, slices: readonly HubAssetSpokeRow[]) {
  const owed = BigInt(asset.owed);
  const added = BigInt(asset.added);
  const share = (x: bigint, of: bigint) => (of > 0n ? Number((x * 1_000_000n) / of) / 10_000 : 0);
  return {
    rows: slices.map((s) => ({
      spoke: s.spoke,
      kind: s.kind,
      addedUsd: usd(s.added, asset.decimals, asset.priceUsd8),
      owedUsd: usd(s.owed, asset.decimals, asset.priceUsd8),
      deficitUsd: usd(s.deficit, asset.decimals, asset.priceUsd8),
      shareOfOwedPct: share(BigInt(s.owed), owed),
      shareOfAddedPct: share(BigInt(s.owed), added),
      headroomUsd: s.kind === "cdp" ? usd(spokeHeadroom(s, asset), asset.decimals, asset.priceUsd8) : 0,
    })),
    idleUsd: usd(asset.liquidity, asset.decimals, asset.priceUsd8),
    blockNumber: asset.blockNumber,
  };
}
