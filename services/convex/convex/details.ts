// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The detail-page cards, one reader each, keyed by page slug. The `borrow/*` and `lend/*` modules expose them as
// queries under the names the app calls; `detailHydration` batches them per page.

import type { QueryCtx } from "./_generated/server";
import { type Values, combineSources, filledBuckets } from "./lib/charts.ts";
import { aboutContractRows } from "./lib/aboutContracts.ts";
import { chainSlug } from "./lib/format.ts";
import { hubAssetKey, interestRateModel, marketAllocation, poolBorrowables, headlineReserve } from "./lib/pages.ts";
import { assetRiskParameters, atRisk, cashflow, contentRiskAssessment, debtPremiumRange, debtRiskAssessment, lendRiskAssessment, lendRiskParameters, liquidationRisk, poolRiskAssessment, poolRiskParameters, type LiquidationWindow } from "./lib/riskViews.ts";
import type { ChangelogRow, ContractAddressRow, PageScope } from "./lib/uiTypes.ts";
import { type World, bySlug, contentOf, lendKey, reserveKey, scopePoints, seriesNow, sliceOf, symbolOf } from "./model.ts";
import { liquidationTotals } from "./lib/rollups.ts";
import { liquidationPricing } from "./rollups.ts";
import type { HubAssetDoc, MarketDoc, SpokeReserveDoc } from "./model.ts";

const contentScope = (s: PageScope) => s;

function pageKey(w: World, scope: PageScope, slug: string): { chainId: number; key: string } | null {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  if (scope === "lend") return { chainId: row.chainId, key: lendKey(row as HubAssetDoc) };
  if (scope === "asset") return { chainId: row.chainId, key: reserveKey(row as SpokeReserveDoc) };
  return { chainId: row.chainId, key: (row as MarketDoc).marketId };
}

/** How a changelog row names the event that made the change ("Risk configuration update"), from its raw kind. */
const CHANGE_SOURCES: Readonly<Record<string, string>> = {
  "AaveSpoke.AddDynamicReserveConfig": "Risk configuration added",
  "AaveSpoke.UpdateDynamicReserveConfig": "Risk configuration update",
  "AaveSpoke.UpdateReserveConfig": "Reserve configuration update",
  "AaveHub.UpdateAssetConfig": "Asset configuration update",
  "AaveHub.UpdateSpokeConfig": "Spoke configuration update",
  "MarketRegistry.MarketOffboarding": "Market offboarding",
};

/** A raw event kind as words: the mapped label, else the event name split ("SetOracle" → "Set oracle"). */
export function changeSourceLabel(kind: string): string {
  const known = CHANGE_SOURCES[kind];
  if (known) return known;
  const name = kind.split(".").pop() ?? kind;
  const words = name.replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export async function readChangelog(ctx: QueryCtx, w: World, scope: PageScope, slug: string): Promise<ChangelogRow[]> {
  const page = pageKey(w, scope, slug);
  if (!page) return [];
  const full = `${page.chainId}:${page.key}`;
  const rows = await ctx.db
    .query("parameterChanges")
    .withIndex("by_scope", (q) => q.eq("scope", scope).eq("chainId", page.chainId).eq("key", full))
    .order("desc")
    .take(50);
  const explorer = (await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", page.chainId)).unique())?.explorerUrl;
  return rows.map((r) => ({
    id: String(r._id),
    parameter: r.parameter,
    previous: r.previous,
    current: r.current,
    date: new Date(r.at).toISOString().slice(0, 10),
    source: changeSourceLabel(r.source),
    executor: "Governance",
    category: "Risk",
    ...(explorer ? { href: `${explorer}/tx/${r.txHash}` } : {}),
  }));
}

export async function readContent(ctx: QueryCtx, w: World, scope: PageScope, slug: string) {
  const page = pageKey(w, scope, slug);
  const c = page ? contentOf(w, contentScope(scope), page.chainId, page.key) : null;
  if (!c) return null;
  return {
    description: c.description,
    // The About card's full text when the listing gives one (the card folds it behind "read more").
    ...(c.longText ? { longText: c.longText } : {}),
    stats: c.stats,
    history: c.history,
    faqs: c.faqs,
    ...(c.links ? { links: c.links } : {}),
    ...(c.risk ? { risk: c.risk } : {}),
    changelog: await readChangelog(ctx, w, scope, slug),
  };
}

export function readInterestRateModel(w: World, scope: "lend" | "asset", slug: string) {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  const asset = scope === "lend" ? (row as HubAssetDoc) : w.assetsByKey.get(hubAssetKey(row as SpokeReserveDoc));
  return asset ? interestRateModel(slug, asset) : null;
}

export function readRiskParameters(w: World, scope: PageScope, slug: string) {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  if (scope === "lend") {
    const a = row as HubAssetDoc;
    return lendRiskParameters(slug, a, w.slices.filter((s) => s.chainId === a.chainId && s.hub === a.hub && s.assetId === a.assetId), symbolOf(w, a.chainId, a.underlying));
  }
  if (scope === "asset") {
    const r = row as SpokeReserveDoc;
    const a = w.assetsByKey.get(hubAssetKey(r));
    const s = sliceOf(w, r);
    return a && s ? assetRiskParameters(slug, r, s, a, symbolOf(w, r.chainId, r.asset)) : null;
  }
  const m = row as MarketDoc;
  const head = headlineReserve(w.reserves.filter((r) => r.chainId === m.chainId), m.spoke);
  const asset = head ? w.assetsByKey.get(hubAssetKey(head)) : undefined;
  const room = readPoolBorrowables(w, slug).map((b) => b.availableNowUsd);
  const borrowRoomUsd = room.length > 0 && room.every((x) => x !== null) ? room.reduce<number>((acc, x) => acc + (x ?? 0), 0) : null;
  return poolRiskParameters(slug, m, asset?.drawnRateRay ?? null, borrowRoomUsd);
}

/**
 * The risk card. A collateral market shows its own premium plus any risk text its listing published; a Lend or Borrow
 * asset page shows its listed risk text, and hides the card when the listing published none.
 */
export function readRisk(w: World, scope: PageScope, slug: string) {
  const page = pageKey(w, scope, slug);
  const c = page ? contentOf(w, scope, page.chainId, page.key) : null;
  if (scope === "pool") {
    const m = bySlug(w, "pool", slug) as MarketDoc | null;
    if (!m) return null;
    const head = headlineReserve(w.reserves.filter((r) => r.chainId === m.chainId), m.spoke);
    const asset = head ? w.assetsByKey.get(hubAssetKey(head)) : undefined;
    return poolRiskAssessment(m, c?.risk, asset?.drawnRateRay ?? null);
  }
  if (scope === "asset") {
    const r = bySlug(w, "asset", slug) as SpokeReserveDoc | null;
    const range = r ? debtPremiumRange(r, w.reserves, w.markets) : null;
    if (r && range) return debtRiskAssessment(range, c?.symbol ?? symbolOf(w, r.chainId, r.asset), c?.risk);
  }
  if (scope === "lend") {
    const a = bySlug(w, "lend", slug) as HubAssetDoc | null;
    if (a) return lendRiskAssessment(a, c?.symbol ?? symbolOf(w, a.chainId, a.underlying), c?.risk);
  }
  return contentRiskAssessment(c?.risk, `${c?.name ?? slug} risk`);
}

/**
 * `readRisk` with the pool's stored risk score (riskScores.ts): the score and level come from the job, and each
 * scored input is added to the card's metrics. Without a stored score the card keeps the premium-based level.
 */
export async function readRiskScored(ctx: QueryCtx, w: World, scope: PageScope, slug: string) {
  const card = readRisk(w, scope, slug);
  if (!card || scope !== "pool") return card;
  const m = bySlug(w, "pool", slug) as MarketDoc | null;
  const scored = m ? await ctx.db.query("riskScores").withIndex("by_market", (q) => q.eq("chainId", m.chainId).eq("marketId", m.marketId)).unique() : null;
  if (!scored) return card;
  return {
    ...card,
    score: scored.score,
    level: scored.level,
    metrics: [...card.metrics, ...scored.factors.map((x) => ({ id: `score:${x.id}`, label: x.label, value: x.value, hint: `${x.points} of the score (${scored.model})` }))],
  };
}

export function readPoolBorrowables(w: World, slug: string) {
  const m = bySlug(w, "pool", slug) as MarketDoc | null;
  return m ? poolBorrowables(m, w.reserves.filter((r) => r.chainId === m.chainId), w.assetsByKey, (t) => symbolOf(w, m.chainId, t)) : [];
}

export function readAllocationForAsset(w: World, slug: string) {
  const r = bySlug(w, "asset", slug) as SpokeReserveDoc | null;
  const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
  if (!r || !a) return [];
  return marketAllocation(r, a, w.markets.filter((m) => m.chainId === r.chainId && m.spoke === r.spoke), w.debts, (s) => {
    const m = w.markets.find((x) => x.slug === s);
    return m ? contentOf(w, "pool", m.chainId, m.marketId) : null;
  });
}

/** Liquidation activity of one market over the last 24 h and the 24 h before, and accounts below 1.10. */
export async function readLiquidationRisk(ctx: QueryCtx, w: World, slug: string) {
  const m = bySlug(w, "pool", slug) as MarketDoc | null;
  if (!m) return null;
  const now = Date.now();
  const logs = await ctx.db
    .query("ingestedLogs")
    .withIndex("by_market", (q) => q.eq("marketKey", `${m.chainId}:${m.marketId}`).gte("at", now - 2 * 86_400_000))
    .collect();
  // Each event is valued at the price of its hour (rollups.ts), not today's price.
  const pricing = await liquidationPricing(ctx, w, m, now - 2 * 86_400_000);
  const window = (from: number, to: number): LiquidationWindow => liquidationTotals(logs as never, from, to, pricing);
  const positions = await ctx.db
    .query("positions")
    .withIndex("by_market", (q) => q.eq("chainId", m.chainId).eq("marketId", m.marketId))
    .collect();
  const risk = atRisk(positions, m.collateralFactorBps);
  const day = new Date(now).toISOString().slice(0, 10);
  return liquidationRisk(slug, day, { ...window(now - 86_400_000, now), ...risk }, { ...window(now - 2 * 86_400_000, now - 86_400_000), ...risk });
}

/** Interest cashflow over 12 months: of a Hub asset (Lend), of one Spoke's draw (Borrow asset). */
export async function readCashflow(ctx: QueryCtx, w: World, scope: "lend" | "asset", slug: string) {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  const asset = scope === "lend" ? (row as HubAssetDoc) : w.assetsByKey.get(hubAssetKey(row as SpokeReserveDoc));
  if (!asset) return null;
  const now = await seriesNow(ctx, asset.chainId);
  const from = now - 365 * 86_400;
  const hubDays = filledBuckets("hubAsset", combineSources("hubAsset", await scopePoints(ctx, "hubAsset", hubAssetKey(asset), "day", from - 86_400)), from, now, "day");
  let owedByDay: Map<number, Values> | null = null;
  if (scope === "asset") {
    const r = row as SpokeReserveDoc;
    const slice = await scopePoints(ctx, "hubAssetSpoke", `${hubAssetKey(asset)}:${r.spoke}`, "day", from - 86_400);
    owedByDay = new Map(filledBuckets("hubAssetSpoke", combineSources("hubAssetSpoke", slice), from, now, "day").map((d) => [d.t, d.values]));
  }
  const days = hubDays.map((d) => ({ t: d.t, hub: d.values, ...(owedByDay ? { owed: owedByDay.get(d.t)?.owed ?? "0" } : {}) }));
  return cashflow(days, asset.decimals, asset.liquidityFeeBps);
}

/** The About card's contract slots of a page (lib/aboutContracts.ts), linked to the explorer of the page's chain. */
export async function readAddresses(ctx: QueryCtx, w: World, scope: PageScope, slug: string): Promise<ContractAddressRow[]> {
  const row = bySlug(w, scope, slug);
  if (!row) return [];
  const dep = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", row.chainId)).unique();
  return aboutContractRows(scope, slug, chainSlug(row.chainId), row, dep);
}

/** The page identity the detail builders fall back on (the app's per-product `getMarket`). */
export function readSiloedMarket(w: World, scope: PageScope, slug: string) {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  const page = pageKey(w, scope, slug)!;
  const c = contentOf(w, scope, page.chainId, page.key);
  const fallback =
    scope === "pool"
      ? { name: (row as MarketDoc).name, symbol: (row as MarketDoc).symbol }
      : { name: symbolOf(w, row.chainId, scope === "lend" ? (row as HubAssetDoc).underlying : (row as SpokeReserveDoc).asset), symbol: "" };
  return {
    slug,
    kind: scope,
    scope,
    chainId: row.chainId,
    name: c?.name ?? fallback.name,
    symbol: c?.symbol ?? (fallback.symbol || fallback.name),
    ...(c?.venueLabel ? { venueLabel: c.venueLabel } : {}),
    ...(c?.category ? { category: c.category } : {}),
    ...(c?.description ? { description: c.description } : {}),
    ...(c?.iconUrl ? { iconUrl: c.iconUrl } : {}),
    ...(c?.visuals ? { visuals: c.visuals } : {}),
    ...(c?.resources ? { resources: c.resources } : {}),
    ...(c?.links ? { links: c.links } : {}),
  };
}
