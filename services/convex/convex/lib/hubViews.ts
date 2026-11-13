// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The views of a chain with several Hubs, built from the scope rows. Totals add the Hub assets of every Hub (where
// the screens show one figure); the breakdowns keep each Hub apart (where they show detail). No Hub figure is stored
// twice: a Hub's totals are the sum of its Hub assets, a credit line's draw is its Spoke slice.

import {
  type CreditLineRow,
  type HubAssetRow,
  type HubAssetSpokeRow,
  type HubRow,
  rayToAprPct,
  rayToApyPct,
  spokeHeadroom,
  usd,
} from "@avana/services-common/views";
import type { CreditLineView, HubBreakdownRow, HubSummary, HubTotals, LendTokenTotals, LendTotals } from "./uiTypes.ts";

type Slugged<T> = T & { readonly slug: string };

/** USD totals of some Hub assets; utilization is borrowed / supplied of those totals. */
export function totalsOf(assets: readonly HubAssetRow[]): HubTotals {
  let suppliedUsd = 0;
  let borrowedUsd = 0;
  let availableUsd = 0;
  for (const a of assets) {
    suppliedUsd += usd(a.added, a.decimals, a.priceUsd8);
    borrowedUsd += usd(a.owed, a.decimals, a.priceUsd8);
    availableUsd += usd(a.liquidity, a.decimals, a.priceUsd8);
  }
  return { suppliedUsd, borrowedUsd, availableUsd, utilizationPct: suppliedUsd > 0 ? Math.min(100, (borrowedUsd / suppliedUsd) * 100) : 0 };
}

/** Supply-weighted mean of a rate over Hub assets. */
function weighted(assets: readonly HubAssetRow[], rate: (a: HubAssetRow) => number): number {
  let weight = 0;
  let sum = 0;
  for (const a of assets) {
    const w = usd(a.added, a.decimals, a.priceUsd8);
    weight += w;
    sum += w * rate(a);
  }
  return weight > 0 ? sum / weight : 0;
}

const hubKey = (x: { chainId: number; hub: string }) => `${x.chainId}:${x.hub}`;

function breakdownRow(h: Slugged<HubRow>, label: string, assets: readonly HubAssetRow[]): HubBreakdownRow {
  return { chainId: h.chainId, hub: h.hub, slug: h.slug, label, tier: h.tier, lendAssets: assets.length, ...totalsOf(assets) };
}

/**
 * The Lend screen's figures: one total over every Hub asset of every Hub, the same split by Hub, and by token, each
 * token's total over its Hubs with one row per Hub. Hubs are in tier order, then by address.
 */
export function lendTotals(
  hubs: readonly Slugged<HubRow>[],
  assets: readonly Slugged<HubAssetRow>[],
  labelOf: (h: { chainId: number; hub: string }) => string,
  symbolOf: (chainId: number, token: string) => string,
): LendTotals {
  const order = [...hubs].sort((x, y) => x.chainId - y.chainId || (x.tier || 99) - (y.tier || 99) || x.hub.localeCompare(y.hub));
  const rank = new Map(order.map((h, i) => [hubKey(h), i]));
  const byHub = order.map((h) => breakdownRow(h, labelOf(h), assets.filter((a) => hubKey(a) === hubKey(h))));
  const tokens = new Map<string, Slugged<HubAssetRow>[]>();
  for (const a of assets) tokens.set(`${a.chainId}:${a.underlying}`, [...(tokens.get(`${a.chainId}:${a.underlying}`) ?? []), a]);
  const byToken: LendTokenTotals[] = [...tokens.values()].map((list) => {
    const sorted = [...list].sort((x, y) => (rank.get(hubKey(x)) ?? 1e9) - (rank.get(hubKey(y)) ?? 1e9));
    const first = sorted[0]!;
    return {
      chainId: first.chainId,
      underlying: first.underlying,
      symbol: symbolOf(first.chainId, first.underlying),
      ...totalsOf(sorted),
      supplyApyPct: weighted(sorted, (a) => rayToApyPct(a.supplyRateRay)),
      hubs: sorted.map((a) => ({
        hub: a.hub,
        label: labelOf(a),
        slug: a.slug,
        ...totalsOf([a]),
        supplyApyPct: rayToApyPct(a.supplyRateRay),
        borrowAprPct: rayToAprPct(a.drawnRateRay),
      })),
    };
  });
  byToken.sort((x, y) => y.suppliedUsd - x.suppliedUsd || x.symbol.localeCompare(y.symbol));
  return { ...totalsOf(assets), hubCount: hubs.length, byHub, byToken };
}

/**
 * One Hub-to-Hub line with its draw: the Spoke's owed amount on the funding Hub's asset, the share of the cap used and
 * what the Spoke can still draw, `min(cap − owed, its headroom on the Hub)`.
 */
export function creditLineView(
  line: CreditLineRow,
  slice: HubAssetSpokeRow | undefined,
  asset: HubAssetRow | undefined,
  labelOf: (h: { chainId: number; hub: string }) => string,
  symbol: string,
): CreditLineView {
  const cap = BigInt(line.cap);
  const owed = slice ? BigInt(slice.owed) : 0n;
  const capLeft = cap > owed ? cap - owed : 0n;
  const room = slice && asset ? spokeHeadroom(slice, asset) : 0n;
  const headroom = capLeft < room ? capLeft : room;
  const value = (units: bigint | string) => (asset ? usd(units, asset.decimals, asset.priceUsd8) : 0);
  return {
    chainId: line.chainId,
    fundingHub: line.fundingHub,
    fundingHubLabel: labelOf({ chainId: line.chainId, hub: line.fundingHub }),
    homeHub: line.homeHub,
    homeHubLabel: labelOf({ chainId: line.chainId, hub: line.homeHub }),
    spoke: line.spoke,
    assetId: line.assetId,
    asset: line.asset,
    symbol,
    enabled: line.enabled,
    cap: line.cap,
    owed: owed.toString(),
    capUsd: value(cap),
    owedUsd: value(owed),
    headroomUsd: value(headroom),
    usedPct: cap > 0n ? Number((owed * 1_000_000n) / cap) / 10_000 : 0,
    fundingHubTotalCapUsd: value(line.total),
    blockNumber: line.blockNumber,
  };
}

/** A Hub's page: its row, totals, lend assets, Spokes and the credit lines it funds and draws on. */
export function hubSummary(
  hub: Slugged<HubRow>,
  label: string,
  assets: readonly HubAssetRow[],
  linesIn: readonly CreditLineView[],
  linesOut: readonly CreditLineView[],
): HubSummary {
  const mine = assets.filter((a) => a.chainId === hub.chainId && a.hub === hub.hub);
  return {
    ...breakdownRow(hub, label, mine),
    recorded: hub.recorded,
    applicationState: hub.applicationState,
    assetCount: hub.assetCount,
    lendSpokes: [...hub.lendSpokes],
    cdpSpokes: [...hub.cdpSpokes],
    fundsLines: [...linesIn],
    drawsOnLines: [...linesOut],
    blockNumber: hub.blockNumber,
  };
}
