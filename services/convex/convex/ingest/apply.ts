// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The mutations of the import. Each applies a whole unit or nothing: one export page (logs, accounts, changelog
// rows, listing operations, checkpoint), one series page, one pool-history range, or one snapshot of current rows.

import { v } from "convex/values";
import type { ExportPage } from "@avana/services-common/export";
import { type SeriesExportPage, type SeriesRecord, mergeValues } from "@avana/services-common/series";
import type { ChainSnapshot } from "@avana/services-common/views";
import { internal } from "../_generated/api";
import type { Doc } from "../_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "../_generated/server";
import { type Resolver, decodeRecord } from "../lib/activity.ts";
import { blockTimes } from "../lib/exportPage.ts";
import { noteFirstSeen } from "../lib/membership.ts";
import { activateReferral } from "../lib/referrals.ts";
import { addSupplyVolume, awardQuestForLog, supplyUsdOfLog } from "../lib/rewards.ts";
import { assetSlugs, defaultSlug, hubLabel } from "../lib/format.ts";

/** A row of the history table every 1,000 blocks: the rebuild's starting points. */
const HISTORY_EVERY = 1_000n;

export const state = internalQuery({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => ({
    deployment: await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique(),
    checkpoint: await ctx.db.query("ingestCheckpoints").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique(),
  }),
});

async function contentSlug(ctx: MutationCtx, scope: "lend" | "asset" | "pool" | "spoke" | "token" | "hub", chainId: number, key: string): Promise<string | null> {
  return (await ctx.db.query("marketContent").withIndex("by_key", (q) => q.eq("scope", scope).eq("chainId", chainId).eq("key", key)).unique())?.slug ?? null;
}

/**
 * A row of one snapshot whose values equal the stored row's is rewritten only once its stored read is this old: every
 * write re-runs each subscription on the table, and the read time (`blockNumber`, `timestamp`, `updatedAt`) moves at
 * every refresh while the values mostly do not. A changed value is written at once.
 */
export const UNCHANGED_REWRITE_MS = 10 * 60_000;

/** Fields that say when a row was read, not what it holds. */
const READ_FIELDS: ReadonlySet<string> = new Set(["_id", "_creationTime", "updatedAt", "blockNumber", "timestamp"]);

/** The row's values in one canonical text: keys sorted, the read fields left out. */
function valuesOf(row: object, top = true): string {
  const canon = (x: unknown, outer: boolean): unknown => {
    if (Array.isArray(x)) return x.map((y) => canon(y, false));
    if (x === null || typeof x !== "object") return x;
    return Object.fromEntries(
      Object.keys(x)
        .filter((k) => !(outer && READ_FIELDS.has(k)) && (x as Record<string, unknown>)[k] !== undefined)
        .sort()
        .map((k) => [k, canon((x as Record<string, unknown>)[k], false)]),
    );
  };
  return JSON.stringify(canon(row, top));
}

/** True when `row` must be written over `existing`: a value changed, or the stored read is UNCHANGED_REWRITE_MS old. */
export function needsWrite(existing: { readonly updatedAt: number }, row: { readonly updatedAt: number }): boolean {
  return valuesOf(existing) !== valuesOf(row) || row.updatedAt - existing.updatedAt >= UNCHANGED_REWRITE_MS;
}

/**
 * Writes the current rows of one snapshot: Hubs (a Hub recorded since the last run is inserted), Hub assets, slices,
 * reserves and markets. Rows of reserves and slices that left the chain's views are removed. An existing row is replaced only when `needsWrite` says so.
 */
export const applySnapshot = internalMutation({
  args: { snapshot: v.any() },
  handler: async (ctx, { snapshot }) => {
    const s = snapshot as ChainSnapshot;
    const now = Date.now();
    const symbol = async (token: string) => (await ctx.db.query("marketContent").withIndex("by_key", (q) => q.eq("scope", "token").eq("chainId", s.chainId).eq("key", token)).unique())?.symbol ?? token.slice(2, 8);
    const labels = new Map(s.hubs.map((h) => [h.hub, hubLabel(h.label, h.hub)]));
    const labelOf = (hub: string) => labels.get(hub as `0x${string}`) ?? hubLabel(null, hub);
    for (const h of s.hubs) {
      const slug = (await contentSlug(ctx, "hub", s.chainId, h.hub)) ?? defaultSlug.hub(s.chainId, labelOf(h.hub));
      const row = { ...h, lendAssetIds: [...h.lendAssetIds], lendSpokes: [...h.lendSpokes], cdpSpokes: [...h.cdpSpokes], slug, updatedAt: now };
      const existing = await ctx.db.query("hubs").withIndex("by_key", (q) => q.eq("chainId", h.chainId).eq("hub", h.hub)).unique();
      if (existing) {
        if (needsWrite(existing, row)) await ctx.db.replace(existing._id, row);
      } else await ctx.db.insert("hubs", row);
    }
    for (const a of s.hubAssets) {
      const slug = (await contentSlug(ctx, "lend", s.chainId, `${a.hub}:${a.assetId}`)) ?? defaultSlug.lend(s.chainId, labelOf(a.hub), await symbol(a.underlying));
      const row = { ...a, lendReserves: [...a.lendReserves], slug, updatedAt: now };
      const existing = await ctx.db.query("hubAssets").withIndex("by_key", (q) => q.eq("chainId", a.chainId).eq("hub", a.hub).eq("assetId", a.assetId)).unique();
      if (existing) {
        if (needsWrite(existing, row)) await ctx.db.replace(existing._id, row);
      } else await ctx.db.insert("hubAssets", row);
    }
    const keepSlices = new Set(s.slices.map((x) => `${x.hub}:${x.assetId}:${x.spoke}`));
    const slices = await ctx.db.query("hubAssetSpokes").withIndex("by_key", (q) => q.eq("chainId", s.chainId)).collect();
    for (const old of slices.filter((x) => !keepSlices.has(`${x.hub}:${x.assetId}:${x.spoke}`))) await ctx.db.delete(old._id);
    for (const sl of s.slices) {
      const row = { ...sl, updatedAt: now };
      const existing = await ctx.db.query("hubAssetSpokes").withIndex("by_key", (q) => q.eq("chainId", sl.chainId).eq("hub", sl.hub).eq("assetId", sl.assetId).eq("spoke", sl.spoke)).unique();
      if (existing) {
        if (needsWrite(existing, row)) await ctx.db.replace(existing._id, row);
      } else await ctx.db.insert("hubAssetSpokes", row);
    }
    const keepReserves = new Set(s.spokeReserves.map((r) => `${r.spoke}:${r.reserveId}`));
    const reserves = await ctx.db.query("spokeReserves").withIndex("by_key", (q) => q.eq("chainId", s.chainId)).collect();
    for (const old of reserves.filter((r) => !keepReserves.has(`${r.spoke}:${r.reserveId}`))) await ctx.db.delete(old._id);
    // Default slugs per (Spoke, Hub, token): the same token drawn from two Hubs on one Spoke gets two pages.
    const defaults = assetSlugs(
      s.chainId,
      await Promise.all(
        s.spokeReserves.map(async (r) => ({
          key: `${r.spoke}:${r.reserveId}`,
          spokeLabel: (await contentSlug(ctx, "spoke", s.chainId, r.spoke)) ?? `spoke-${r.spoke.slice(2, 8)}`,
          hubLabel: labelOf(r.hub),
          symbol: await symbol(r.asset),
          asset: r.asset,
        })),
      ),
    );
    for (const r of s.spokeReserves) {
      const slug = (await contentSlug(ctx, "asset", s.chainId, `${r.spoke}:${r.reserveId}`)) ?? defaults.get(`${r.spoke}:${r.reserveId}`)!;
      const row = { ...r, slug, updatedAt: now };
      const existing = await ctx.db.query("spokeReserves").withIndex("by_key", (q) => q.eq("chainId", r.chainId).eq("spoke", r.spoke).eq("reserveId", r.reserveId)).unique();
      if (existing) {
        if (needsWrite(existing, row)) await ctx.db.replace(existing._id, row);
      } else await ctx.db.insert("spokeReserves", row);
    }
    for (const m of s.markets) {
      const slug = (await contentSlug(ctx, "pool", s.chainId, m.marketId)) ?? defaultSlug.pool(s.chainId, m.marketId);
      const row = { ...m, tokens: [...m.tokens], tokenDecimals: [...m.tokenDecimals], caps: { ...m.caps, tokenUsdCaps8: [...m.caps.tokenUsdCaps8] }, borrow: [...m.borrow], slug, updatedAt: now };
      const existing = await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", m.chainId).eq("marketId", m.marketId)).unique();
      if (existing) {
        if (needsWrite(existing, row)) await ctx.db.replace(existing._id, row);
      } else await ctx.db.insert("markets", row);
    }
  },
});

/** Every Lend Spoke of a chain: the deployment's and those the sampler found on Hubs recorded later. */
export async function lendSpokesOf(ctx: QueryCtx, dep: Doc<"deployments">): Promise<Set<string>> {
  const hubs = (await ctx.db.query("hubs").collect()).filter((h) => h.chainId === dep.chainId);
  return new Set([...dep.lendSpokes, ...hubs.flatMap((h) => h.lendSpokes)]);
}

export function resolver(ctx: QueryCtx, dep: Doc<"deployments">, lendSpokes: ReadonlySet<string>): Resolver {
  const chainId = dep.chainId;
  return {
    chainId,
    isLendSpoke: (spoke) => lendSpokes.has(spoke),
    async hubAssetOfReserve(spoke, reserveId) {
      if (lendSpokes.has(spoke)) {
        const a = (await ctx.db.query("hubAssets").collect()).find((x) => x.chainId === chainId && x.lendReserves.some((r) => r.spoke === spoke && r.reserveId === reserveId));
        return a ? `${chainId}:${a.hub}:${a.assetId}` : null;
      }
      const r = await ctx.db.query("spokeReserves").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("spoke", spoke).eq("reserveId", reserveId)).unique();
      return r ? `${chainId}:${r.hub}:${r.assetId}` : null;
    },
    async spokeReserveOfHubAsset(spoke, hubAssetKey) {
      const r = (await ctx.db.query("spokeReserves").withIndex("by_spoke", (q) => q.eq("chainId", chainId).eq("spoke", spoke)).collect()).find((x) => `${chainId}:${x.hub}:${x.assetId}` === hubAssetKey);
      return r ? `${chainId}:${r.spoke}:${r.reserveId}` : null;
    },
    async marketOfCollateralReserve(spoke, reserveId) {
      const m = (await ctx.db.query("markets").withIndex("by_spoke", (q) => q.eq("chainId", chainId).eq("spoke", spoke)).collect()).find((x) => x.reserveId === reserveId);
      return m ? `${chainId}:${m.marketId}` : null;
    },
    async account(proxy) {
      const a = (await ctx.db.query("accounts").collect()).find((x) => x.chainId === chainId && x.proxy === proxy);
      return a ? { wallet: a.wallet, marketKey: `${chainId}:${a.marketId}` } : null;
    },
    async previous(scope, key, parameter) {
      const last = await ctx.db
        .query("parameterChanges")
        .withIndex("by_parameter", (q) => q.eq("chainId", chainId).eq("scope", scope).eq("key", key).eq("parameter", parameter))
        .order("desc")
        .first();
      return last?.current ?? null;
    },
  };
}

/**
 * Applies one validated export page if it starts at the checkpoint (a second, overlapping run sees the moved
 * checkpoint and writes nothing). A record already stored is skipped; the same key with another block hash aborts
 * the mutation, which stops the import for the rebuild (README, "Reorg rebuild").
 */
export const applyPage = internalMutation({
  args: { chainId: v.number(), page: v.any() },
  handler: async (ctx, { chainId, page: raw }) => {
    const page = raw as ExportPage;
    const dep = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if (!dep) throw new Error(`no deployment for chain ${chainId}`);
    const cp = await ctx.db.query("ingestCheckpoints").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if ((cp?.throughBlock ?? null) !== (page.after?.throughBlock ?? null)) return { applied: false };
    const times = blockTimes(page);
    const res = resolver(ctx, dep, await lendSpokesOf(ctx, dep));
    for (const r of page.records) {
      const existing = await ctx.db.query("ingestedLogs").withIndex("by_key", (q) => q.eq("key", r.key)).unique();
      if (existing) {
        if (existing.blockHash !== r.blockHash) throw new Error(`log ${r.key} arrived with another block hash: rebuild needed`);
        continue;
      }
      const d = await decodeRecord(r, times.get(r.blockNumber) ?? 0, res);
      await ctx.db.insert("ingestedLogs", { ...d.log, args: d.log.args });
      if (d.log.wallet) {
        await noteFirstSeen(ctx, d.log.wallet, d.log.at, "onchain");
        await awardQuestForLog(ctx, d.log.wallet, d.log.kind, d.log.at);
        await activateReferral(ctx, d.log.wallet, { log: d.log.kind }, d.log.at);
        await addSupplyVolume(ctx, d.log.wallet, await supplyUsdOfLog(ctx, d.log), d.log.at);
      }
      if (d.account) {
        const found = await ctx.db.query("accounts").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("spoke", d.account!.spoke).eq("proxy", d.account!.proxy)).unique();
        if (!found) await ctx.db.insert("accounts", { chainId, ...d.account, blockNumber: r.blockNumber });
      }
      for (const c of d.changes) await ctx.db.insert("parameterChanges", { chainId, ...c, at: d.log.at, blockNumber: r.blockNumber, txHash: r.txHash, source: r.kind });
      if (d.listing) await listingEvent(ctx, chainId, d.listing, r.blockNumber);
      if (r.kind === "MarketRegistry.MarketRegistered" && !/^0x0{40}$/.test(String(r.args.pool))) {
        await ctx.scheduler.runAfter(0, internal.ingest.poolHistory.backfill, { chainId, pool: String(r.args.pool).toLowerCase(), listedBlock: r.blockNumber });
      }
    }
    const row = {
      chainId,
      throughBlock: page.toBlock,
      throughBlockHash: page.toBlockHash,
      schemaVersion: page.schemaVersion,
      lastPageHash: page.pageHash,
      seriesThroughTime: cp?.seriesThroughTime ?? -1,
      updatedAt: Date.now(),
    };
    if (cp) await ctx.db.replace(cp._id, row);
    else await ctx.db.insert("ingestCheckpoints", row);
    const from = BigInt(page.fromBlock);
    const to = BigInt(page.toBlock);
    if (to / HISTORY_EVERY > (from - 1n) / HISTORY_EVERY || from === 0n) {
      await ctx.db.insert("ingestCheckpointHistory", { chainId, throughBlock: page.toBlock, throughBlockHash: page.toBlockHash });
    }
    return { applied: true };
  },
});

/** A salt names the metadata file; the load runs once the operation executes. */
async function listingEvent(ctx: MutationCtx, chainId: number, l: { operationId: string; salt?: string; executed: boolean }, block: string) {
  const op = await ctx.db.query("listingOperations").withIndex("by_op", (q) => q.eq("chainId", chainId).eq("operationId", l.operationId)).unique();
  if (!l.executed) {
    if (!op && l.salt && !/^0x0{64}$/.test(l.salt)) await ctx.db.insert("listingOperations", { chainId, operationId: l.operationId, salt: l.salt, status: "scheduled", updatedAt: Date.now() });
    return;
  }
  if (!op || op.status !== "scheduled") return; // no salt, or a later call of the same batch
  await ctx.db.patch(op._id, { status: "executed", executedBlock: block, updatedAt: Date.now() });
  await ctx.scheduler.runAfter(0, internal.listing.load.loadMetadata, { chainId, operationId: l.operationId });
}

async function upsertSeries(ctx: MutationCtx, r: SeriesRecord, source: "live" | "history") {
  const existing = await ctx.db
    .query("series")
    .withIndex("by_bucket", (q) => q.eq("scopeKind", r.scopeKind).eq("scopeKey", r.scopeKey).eq("resolution", r.resolution).eq("bucketStart", r.bucketStart).eq("source", source))
    .unique();
  const values = existing && source === "history" ? mergeValues(r.scopeKind, existing.values, r.values) : { ...r.values };
  const row = { chainId: r.chainId, scopeKind: r.scopeKind, scopeKey: r.scopeKey, resolution: r.resolution, bucketStart: r.bucketStart, source, blockNumber: r.blockNumber, values };
  if (existing) await ctx.db.replace(existing._id, row);
  else await ctx.db.insert("series", row);
}

/** Stores closed buckets; the latest market-debt and position buckets also refresh their current rows. */
export const applySeriesPage = internalMutation({
  args: { chainId: v.number(), page: v.any() },
  handler: async (ctx, { chainId, page: raw }) => {
    const page = raw as SeriesExportPage;
    const cp = await ctx.db.query("ingestCheckpoints").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if (!cp || cp.seriesThroughTime !== (page.after?.throughTime ?? -1)) return { applied: false };
    for (const r of page.records) {
      await upsertSeries(ctx, r, "live");
      if (r.scopeKind === "marketReserve" && r.resolution === "hour") {
        const [, marketId, spoke, reserveId] = r.scopeKey.split(":") as [string, string, string, string];
        const row = { chainId, marketId, spoke, reserveId, debt: r.values.debt ?? "0", borrowers: Number(r.values.borrowers ?? "0"), blockNumber: r.blockNumber, updatedAt: Date.now() };
        const existing = (await ctx.db.query("marketReserveDebt").withIndex("by_market", (q) => q.eq("chainId", chainId).eq("marketId", marketId)).collect()).find((d) => d.spoke === spoke && d.reserveId === reserveId);
        if (!existing) await ctx.db.insert("marketReserveDebt", row);
        else if (BigInt(existing.blockNumber) <= BigInt(r.blockNumber)) await ctx.db.replace(existing._id, row);
      }
      // The sampler writes a market's debt reserves only while they carry debt, next to the market's own point of the
      // same block; a debt row older than that point was repaid or liquidated since.
      if (r.scopeKind === "market" && r.resolution === "hour") {
        const [, marketId] = r.scopeKey.split(":") as [string, string];
        const debts = await ctx.db.query("marketReserveDebt").withIndex("by_market", (q) => q.eq("chainId", chainId).eq("marketId", marketId)).collect();
        for (const d of debts) if (BigInt(d.blockNumber) < BigInt(r.blockNumber)) await ctx.db.delete(d._id);
      }
      if (r.scopeKind === "position" && r.resolution === "day") {
        const [, spoke, proxy] = r.scopeKey.split(":") as [string, string, string];
        const account = await ctx.db.query("accounts").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("spoke", spoke).eq("proxy", proxy)).unique();
        const row = {
          chainId,
          spoke,
          proxy,
          ...(account ? { wallet: account.wallet } : {}),
          marketId: r.values.marketId ?? "0",
          collateralUnits: r.values.collateralUnits ?? "0",
          collateralUsd8: r.values.collateralUsd8 ?? "0",
          debtUsd8: r.values.debtUsd8 ?? "0",
          blockNumber: r.blockNumber,
          updatedAt: Date.now(),
        };
        const existing = await ctx.db.query("positions").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("spoke", spoke).eq("proxy", proxy)).unique();
        if (!existing) await ctx.db.insert("positions", row);
        else if (BigInt(existing.blockNumber) <= BigInt(r.blockNumber)) await ctx.db.replace(existing._id, row);
      }
    }
    await ctx.db.patch(cp._id, { seriesThroughTime: page.next.throughTime, updatedAt: Date.now() });
    return { applied: true };
  },
});

/** The pool's import progress, created on the first call with the range to cover. */
export const poolBackfill = internalMutation({
  args: { chainId: v.number(), pool: v.string(), fromBlock: v.string(), listedBlock: v.string() },
  handler: async (ctx, a) => {
    const found = await ctx.db.query("poolBackfills").withIndex("by_pool", (q) => q.eq("chainId", a.chainId).eq("pool", a.pool)).unique();
    if (found) return found;
    const row = { ...a, throughBlock: (BigInt(a.fromBlock) - 1n).toString(), updatedAt: Date.now() };
    await ctx.db.insert("poolBackfills", row);
    return row;
  },
});

/**
 * Merges one pool-history range if it starts right after the stored progress, so a retried or duplicated range
 * is applied once; adjacent ranges combine bucket by bucket by the pool series' merge rules.
 */
export const applyPoolHistory = internalMutation({
  args: { chainId: v.number(), pool: v.string(), fromBlock: v.string(), toBlock: v.string(), records: v.any() },
  handler: async (ctx, a) => {
    const progress = await ctx.db.query("poolBackfills").withIndex("by_pool", (q) => q.eq("chainId", a.chainId).eq("pool", a.pool)).unique();
    if (!progress || BigInt(progress.throughBlock) + 1n !== BigInt(a.fromBlock)) return { applied: false };
    for (const r of a.records as SeriesRecord[]) await upsertSeries(ctx, r, "history");
    await ctx.db.patch(progress._id, { throughBlock: a.toBlock, updatedAt: Date.now() });
    return { applied: true };
  },
});

/**
 * Rewinds a chain to a checkpoint whose hash still matches Convex's RPC: deletes up to `batch` logs above it and
 * moves the checkpoint once none remain. Called repeatedly by the pull until it reports done.
 */
export const rewind = internalMutation({
  args: { chainId: v.number(), throughBlock: v.string(), throughBlockHash: v.string(), batch: v.number() },
  handler: async (ctx, { chainId, throughBlock, throughBlockHash, batch }) => {
    const above = (await ctx.db.query("ingestedLogs").withIndex("by_at").order("desc").take(batch * 4)).filter((l) => l.chainId === chainId && BigInt(l.blockNumber) > BigInt(throughBlock)).slice(0, batch);
    for (const l of above) await ctx.db.delete(l._id);
    if (above.length > 0) return { done: false };
    const later = (b: string) => BigInt(b) > BigInt(throughBlock);
    for (const c of (await ctx.db.query("parameterChanges").collect()).filter((c) => c.chainId === chainId && later(c.blockNumber))) await ctx.db.delete(c._id);
    for (const a of (await ctx.db.query("accounts").collect()).filter((a) => a.chainId === chainId && later(a.blockNumber))) await ctx.db.delete(a._id);
    for (const h of (await ctx.db.query("ingestCheckpointHistory").withIndex("by_chain_block", (q) => q.eq("chainId", chainId)).collect()).filter((h) => BigInt(h.throughBlock) > BigInt(throughBlock))) await ctx.db.delete(h._id);
    const cp = await ctx.db.query("ingestCheckpoints").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if (cp) await ctx.db.patch(cp._id, { throughBlock, throughBlockHash, updatedAt: Date.now() });
    return { done: true };
  },
});

/** Keeps 30 days of logs (README, "Tables"); older activity comes from the export's history endpoint. */
export const prune = internalMutation({
  args: {},
  handler: async (ctx) => {
    const old = await ctx.db.query("ingestedLogs").withIndex("by_at", (q) => q.lt("at", Date.now() - 30 * 86_400_000)).take(500);
    for (const l of old) await ctx.db.delete(l._id);
    return { deleted: old.length };
  },
});
