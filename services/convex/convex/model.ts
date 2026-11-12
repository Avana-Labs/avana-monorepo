// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads shared by the queries: the scope rows, their content and the joins between them. A Borrow asset page and
// the Lend page join the same `hubAssets` document; nothing here copies a Hub figure into another row.

import type { CreditLineRow, HubAssetRow, HubAssetSpokeRow, HubRow, MarketReserveDebtRow, MarketRow, SpokeReserveRow } from "@avana/services-common/views";
import type { Doc } from "./_generated/dataModel";
import type { QueryCtx } from "./_generated/server";
import { combineSources, sumOver, type StoredPoint } from "./lib/charts.ts";
import { hubLabel } from "./lib/format.ts";
import { creditLineView } from "./lib/hubViews.ts";
import { hubAssetKey, lendSnapshot, assetSnapshot, poolSnapshot } from "./lib/pages.ts";
import type { CreditLineView, MarketSnapshotRow, PageContent, PageScope } from "./lib/uiTypes.ts";

export type ContentScope = Doc<"marketContent">["scope"];

/** A stored row typed as the shared row it was written from (addresses are stored lower-case hex). */
type Stored<Row> = Row & { readonly slug: string; readonly updatedAt: number };
export type HubAssetDoc = Stored<HubAssetRow>;
export type SpokeReserveDoc = Stored<SpokeReserveRow>;
export type MarketDoc = Stored<MarketRow>;
export type HubDoc = Stored<HubRow>;
export type CreditLineDoc = CreditLineRow & { readonly updatedAt: number };

export interface World {
  readonly hubs: HubDoc[];
  readonly creditLines: CreditLineDoc[];
  readonly hubAssets: HubAssetDoc[];
  readonly slices: (HubAssetSpokeRow & { updatedAt: number })[];
  readonly reserves: SpokeReserveDoc[];
  readonly markets: MarketDoc[];
  readonly debts: MarketReserveDebtRow[];
  readonly content: Doc<"marketContent">[];
  readonly assetsByKey: Map<string, HubAssetDoc>;
  /** `chainId:hub` → Hub. */
  readonly hubsByKey: Map<string, HubDoc>;
}

/** The typed view of stored rows; the schema stores exactly these fields. */
export const asRows = {
  hubs: (d: Doc<"hubs">[]) => d as unknown as HubDoc[],
  creditLines: (d: Doc<"creditLines">[]) => d as unknown as CreditLineDoc[],
  hubAssets: (d: Doc<"hubAssets">[]) => d as unknown as HubAssetDoc[],
  slices: (d: Doc<"hubAssetSpokes">[]) => d as unknown as (HubAssetSpokeRow & { updatedAt: number })[],
  reserves: (d: Doc<"spokeReserves">[]) => d as unknown as SpokeReserveDoc[],
  markets: (d: Doc<"markets">[]) => d as unknown as MarketDoc[],
  debts: (d: Doc<"marketReserveDebt">[]) => d as unknown as MarketReserveDebtRow[],
};

/** Every scope row. The tables hold one row per Hub, Hub asset, Spoke slice, line, reserve and market: hundreds of rows. */
export async function loadWorld(ctx: QueryCtx): Promise<World> {
  const [hubs, creditLines, hubAssets, slices, reserves, markets, debts, content] = await Promise.all([
    ctx.db.query("hubs").collect(),
    ctx.db.query("creditLines").collect(),
    ctx.db.query("hubAssets").collect(),
    ctx.db.query("hubAssetSpokes").collect(),
    ctx.db.query("spokeReserves").collect(),
    ctx.db.query("markets").collect(),
    ctx.db.query("marketReserveDebt").collect(),
    ctx.db.query("marketContent").collect(),
  ]);
  const assets = asRows.hubAssets(hubAssets);
  const hubRows = asRows.hubs(hubs);
  return {
    hubs: hubRows,
    creditLines: asRows.creditLines(creditLines),
    hubAssets: assets,
    slices: asRows.slices(slices),
    reserves: asRows.reserves(reserves),
    markets: asRows.markets(markets),
    debts: asRows.debts(debts),
    content,
    assetsByKey: new Map(assets.map((a) => [hubAssetKey(a), a])),
    hubsByKey: new Map(hubRows.map((h) => [`${h.chainId}:${h.hub}`, h])),
  };
}

/** A Hub's label: its listing content name, else the manifest's label, else its short address. */
export function hubLabelOf(w: World, chainId: number, hub: string): string {
  return contentOf(w, "hub", chainId, hub)?.name ?? hubLabel(w.hubsByKey.get(`${chainId}:${hub}`)?.label, hub);
}

/** Hub-to-Hub credit lines that pass `keep`, each joined with its draw (the Spoke's slice) and its asset's price. */
export function creditLineViews(w: World, keep: (l: CreditLineDoc) => boolean): CreditLineView[] {
  return w.creditLines.filter(keep).map((l) => {
    const slice = w.slices.find((s) => s.chainId === l.chainId && s.hub === l.fundingHub && s.assetId === l.assetId && s.spoke === l.spoke);
    const asset = w.assetsByKey.get(hubAssetKey({ chainId: l.chainId, hub: l.fundingHub, assetId: l.assetId }));
    return creditLineView(l, slice, asset, (h) => hubLabelOf(w, h.chainId, h.hub), symbolOf(w, l.chainId, l.asset));
  });
}

/**
 * The Hub asset whose price values a token on a chain: on `preferHub` when that Hub lists it, else on the Hub of the
 * lowest tier, then the lowest address. A token on several Hubs has one price per Lend Spoke oracle; this picks one
 * deterministically for figures that are not tied to a Hub (pool volume, the price list).
 */
export function priceAsset(w: World, chainId: number, token: string, preferHub?: string): HubAssetDoc | undefined {
  const all = w.hubAssets.filter((a) => a.chainId === chainId && a.underlying === token);
  const tier = (a: HubAssetDoc) => w.hubsByKey.get(`${chainId}:${a.hub}`)?.tier || Number.MAX_SAFE_INTEGER;
  return all.find((a) => a.hub === preferHub) ?? [...all].sort((x, y) => tier(x) - tier(y) || x.hub.localeCompare(y.hub))[0];
}

export function contentOf(w: World, scope: ContentScope, chainId: number, key: string): PageContent | null {
  return w.content.find((c) => c.scope === scope && c.chainId === chainId && c.key === key) ?? null;
}

/** A token's symbol from its content, or its short address until the listing names it. */
export function symbolOf(w: World, chainId: number, token: string): string {
  return contentOf(w, "token", chainId, token)?.symbol ?? `${token.slice(0, 6)}…`;
}

export function spokeSlug(w: World, chainId: number, spoke: string): string {
  return contentOf(w, "spoke", chainId, spoke)?.slug ?? spoke;
}

export const reserveKey = (r: { chainId: number; spoke: string; reserveId: string }) => `${r.spoke}:${r.reserveId}`;
export const lendKey = (a: { hub: string; assetId: string }) => `${a.hub}:${a.assetId}`;

export function sliceOf(w: World, r: SpokeReserveRow): (HubAssetSpokeRow & { updatedAt: number }) | undefined {
  return w.slices.find((s) => s.chainId === r.chainId && s.hub === r.hub && s.assetId === r.assetId && s.spoke === r.spoke);
}

/** Pool volume and fees over the last 24 hourly buckets, valued at the Lend Spoke price of each token (`priceAsset`). */
export async function pool24h(ctx: QueryCtx, w: World, m: MarketDoc, now: number): Promise<{ volumeUsd: number; feesUsd: number }> {
  const key = `${m.chainId}:${m.pool}`;
  const from = Math.floor(now / 3_600) * 3_600 - 24 * 3_600;
  const rows = await ctx.db
    .query("series")
    .withIndex("by_scope", (q) => q.eq("scopeKind", "pool").eq("scopeKey", key).eq("resolution", "hour").gte("bucketStart", from))
    .collect();
  const buckets = combineSources("pool", rows as StoredPoint[]);
  const priced = m.tokens.map((t, i) => ({ i, asset: priceAsset(w, m.chainId, t, m.hub) }));
  const side = priced.find((p) => p.asset !== undefined);
  if (!side?.asset) return { volumeUsd: 0, feesUsd: 0 };
  const price = Number(BigInt(side.asset.priceUsd8)) / 1e8;
  const scale = 10 ** side.asset.decimals;
  const value = (metric: string) => (Number(sumOver(buckets, `${metric}${side.i}`, from, Number.MAX_SAFE_INTEGER)) / scale) * price;
  // Fees are charged on the input side of each swap, so both tokens' fees count; the other side at the same price.
  const otherFees = Number(sumOver(buckets, `fees${1 - side.i}`, from, Number.MAX_SAFE_INTEGER)) / 10 ** (m.tokenDecimals[1 - side.i] ?? side.asset.decimals);
  return { volumeUsd: value("volume"), feesUsd: value("fees") + otherFees * price };
}

/** Every list row, one per Lend asset, CDP debt reserve and market. */
export async function snapshotRows(ctx: QueryCtx, w: World, now: number, only?: PageScope): Promise<MarketSnapshotRow[]> {
  const rows: MarketSnapshotRow[] = [];
  if (!only || only === "lend") {
    for (const a of w.hubAssets) rows.push(lendSnapshot(a, contentOf(w, "lend", a.chainId, lendKey(a)), symbolOf(w, a.chainId, a.underlying), hubLabelOf(w, a.chainId, a.hub)));
  }
  if (!only || only === "asset") {
    for (const r of w.reserves) {
      const asset = w.assetsByKey.get(hubAssetKey(r));
      const slice = sliceOf(w, r);
      if (!asset || !slice) continue;
      rows.push(
        assetSnapshot(r, slice, asset, contentOf(w, "asset", r.chainId, reserveKey(r)), symbolOf(w, r.chainId, r.asset), spokeSlug(w, r.chainId, r.spoke), hubLabelOf(w, r.chainId, r.hub)),
      );
    }
  }
  if (!only || only === "pool") {
    for (const m of w.markets) {
      const debts = w.debts.filter((d) => d.chainId === m.chainId && d.marketId === m.marketId);
      const reserves = w.reserves.filter((r) => r.chainId === m.chainId);
      rows.push(poolSnapshot(m, debts, reserves, w.assetsByKey, await pool24h(ctx, w, m, now), contentOf(w, "pool", m.chainId, m.marketId)));
    }
  }
  return rows;
}

/** The scope row behind a page slug. */
export function bySlug(w: World, scope: PageScope, slug: string): HubAssetDoc | SpokeReserveDoc | MarketDoc | null {
  if (scope === "lend") return w.hubAssets.find((a) => a.slug === slug) ?? null;
  if (scope === "asset") return w.reserves.find((r) => r.slug === slug) ?? null;
  return w.markets.find((m) => m.slug === slug) ?? null;
}

/** All stored points of one scope at one resolution, both sources. */
export async function scopePoints(ctx: QueryCtx, scopeKind: string, scopeKey: string, resolution: "hour" | "day", from = 0): Promise<StoredPoint[]> {
  return (await ctx.db
    .query("series")
    .withIndex("by_scope", (q) => q.eq("scopeKind", scopeKind).eq("scopeKey", scopeKey).eq("resolution", resolution).gte("bucketStart", from))
    .collect()) as StoredPoint[];
}
