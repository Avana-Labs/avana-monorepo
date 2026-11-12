// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The detail-page cards, one reader each, keyed by page slug. The `borrow/*` and `lend/*` modules expose them as
// queries under the names the app calls; `detailHydration` batches them per page.

import type { QueryCtx } from "./_generated/server";
import { type Values, combineSources, filledBuckets } from "./lib/charts.ts";
import { chainSlug } from "./lib/format.ts";
import { hubAssetKey, interestRateModel, marketAllocation, poolBorrowables, headlineReserve } from "./lib/pages.ts";
import { assetRiskParameters, atRisk, cashflow, lendRiskParameters, liquidationRisk, poolRiskAssessment, poolRiskParameters, type LiquidationWindow } from "./lib/riskViews.ts";
import type { ChangelogRow, ContractAddressRow, PageScope } from "./lib/uiTypes.ts";
import { type World, bySlug, contentOf, lendKey, reserveKey, scopePoints, sliceOf, symbolOf } from "./model.ts";
import type { HubAssetDoc, MarketDoc, SpokeReserveDoc } from "./model.ts";

const contentScope = (s: PageScope) => s;

function pageKey(w: World, scope: PageScope, slug: string): { chainId: number; key: string } | null {
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  if (scope === "lend") return { chainId: row.chainId, key: lendKey(row as HubAssetDoc) };
  if (scope === "asset") return { chainId: row.chainId, key: reserveKey(row as SpokeReserveDoc) };
  return { chainId: row.chainId, key: (row as MarketDoc).marketId };
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
    source: r.source,
    executor: "Governance",
    category: "Risk",
    ...(explorer ? { href: `${explorer}/tx/${r.txHash}` } : {}),
  }));
}

export async function readContent(ctx: QueryCtx, w: World, scope: PageScope, slug: string) {
  const page = pageKey(w, scope, slug);
  const c = page ? contentOf(w, contentScope(scope), page.chainId, page.key) : null;
  if (!c) return null;
  return { description: c.description, stats: c.stats, history: c.history, faqs: c.faqs, changelog: await readChangelog(ctx, w, scope, slug) };
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
  return poolRiskParameters(slug, m, asset?.drawnRateRay ?? null);
}

/** The premium card: a collateral market's own premium. Supply markets and debt reserves have none (card hidden). */
export function readRisk(w: World, scope: PageScope, slug: string) {
  if (scope !== "pool") return null;
  const m = bySlug(w, "pool", slug) as MarketDoc | null;
  return m ? poolRiskAssessment(m) : null;
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
  const window = (from: number, to: number): LiquidationWindow => {
    let liquidations = 0;
    let collateralSeizedUsd = 0;
    let debtRepaidUsd = 0;
    let badDebtUsd = 0;
    for (const l of logs) {
      if (l.at < from || l.at >= to) continue;
      if (l.kind === "AaveSpoke.ReportDeficit") {
        // Deficit in drawn shares, valued at the current drawn index and price of the reserve's Hub asset.
        const r = w.reserves.find((x) => `${x.chainId}:${x.spoke}:${x.reserveId}` === l.spokeReserveKey);
        const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
        const shares = BigInt(String((l.args as { drawnShares: string }).drawnShares));
        if (a) badDebtUsd += Number((((shares * BigInt(a.drawnIndexRay)) / 10n ** 27n) * BigInt(a.priceUsd8)) / 10n ** BigInt(a.decimals)) / 1e8;
        continue;
      }
      if (l.kind !== "LPVaultSwap.LiquidationSettled") continue;
      const report = (l.args as { report: { debtReserveId: string; debtRepaid: string; unitsSeized: string } }).report;
      liquidations += 1;
      collateralSeizedUsd += Number((BigInt(report.unitsSeized) * BigInt(m.acceptedPrice)) / 10n ** BigInt(m.vaultDecimals)) / 1e8;
      const r = w.reserves.find((x) => x.chainId === m.chainId && x.spoke === m.spoke && x.reserveId === String(report.debtReserveId));
      const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
      if (a) debtRepaidUsd += Number((BigInt(report.debtRepaid) * BigInt(a.priceUsd8)) / 10n ** BigInt(a.decimals)) / 1e8;
    }
    return { liquidations, collateralSeizedUsd, debtRepaidUsd, badDebtUsd };
  };
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
  const from = Math.floor(Date.now() / 1000) - 365 * 86_400;
  const hubDays = filledBuckets("hubAsset", combineSources("hubAsset", await scopePoints(ctx, "hubAsset", hubAssetKey(asset), "day", from - 86_400)), from, Math.floor(Date.now() / 1000), "day");
  let owedByDay: Map<number, Values> | null = null;
  if (scope === "asset") {
    const r = row as SpokeReserveDoc;
    const slice = await scopePoints(ctx, "hubAssetSpoke", `${hubAssetKey(asset)}:${r.spoke}`, "day", from - 86_400);
    owedByDay = new Map(filledBuckets("hubAssetSpoke", combineSources("hubAssetSpoke", slice), from, Math.floor(Date.now() / 1000), "day").map((d) => [d.t, d.values]));
  }
  const days = hubDays.map((d) => ({ t: d.t, hub: d.values, ...(owedByDay ? { owed: owedByDay.get(d.t)?.owed ?? "0" } : {}) }));
  return cashflow(days, asset.decimals, asset.liquidityFeeBps);
}

/** The contract rows of a page: token, Hub, Spokes, vault token, oracle, pool, with explorer links. */
export async function readAddresses(ctx: QueryCtx, w: World, scope: PageScope, slug: string): Promise<ContractAddressRow[]> {
  const row = bySlug(w, scope, slug);
  if (!row) return [];
  const dep = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", row.chainId)).unique();
  const href = (a: string) => (dep ? `${dep.explorerUrl}/address/${a}` : "");
  const chain = chainSlug(row.chainId);
  const rows: [string, string][] = [];
  if (scope === "lend") {
    const a = row as HubAssetDoc;
    rows.push(["Token", a.underlying], ["Hub", a.hub], ["Lend Spoke", a.lend.spoke]);
    if (a.exposure) rows.push(["Coverage Spoke", a.exposure.coverageSpoke]);
  } else if (scope === "asset") {
    const r = row as SpokeReserveDoc;
    rows.push(["Token", r.asset], ["Hub", r.hub], ["CDP Spoke", r.spoke]);
  } else {
    const m = row as MarketDoc;
    rows.push(["Pool", m.pool], ["Vault token", m.vaultToken], ["LP oracle", m.lpOracle], ["CDP Spoke", m.spoke], ["Hub", m.hub]);
  }
  return rows.map(([label, address]) => ({ slug, salt: "", address, label, href: href(address), chain, isSynthetic: false as const }));
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
  };
}
