// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Transaction progress (README, "Transaction progress"; states in lib/intents.ts). The signed-in wallet records the
// hash of a transaction it just submitted; a cron per chain reads each open intent's receipt over Convex's own RPC
// and moves it, so progress survives a page reload or another device. Convex stores no target, amount or calldata.

import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { codedError } from "./codedError";
import { INTENT_KINDS, type IntentState, type IntentStatus, isFinal, nextIntentState } from "./lib/intents.ts";
import { explorerLinks } from "./lib/explorer.ts";
import { noteFirstSeen } from "./lib/membership.ts";
import { rpcClient } from "./lib/rpc.ts";
import { consumeWriteBudget } from "./writeRateLimit";
import { requireWalletSession } from "./walletAuth";

const TX_HASH = /^0x[0-9a-f]{64}$/;
/** Open intents read per tracker run and chain; the rest wait for the next run. */
const TRACK_BATCH = 50;

const pageArg = v.optional(v.object({ scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool")), slug: v.string() }));

export const submit = mutation({
  args: { wallet: v.string(), chainId: v.number(), txHash: v.string(), kind: v.string(), page: pageArg },
  handler: async (ctx, { wallet, chainId, txHash, kind, page }) => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    const hash = txHash.toLowerCase();
    if (!TX_HASH.test(hash)) throw codedError("INVALID_INTENT: txHash is a 32-byte hash");
    if (!(INTENT_KINDS as readonly string[]).includes(kind)) throw codedError("INVALID_INTENT: unknown kind");
    if (page && (page.slug.length === 0 || page.slug.length > 96)) throw codedError("INVALID_INTENT: page slug");
    if (!(await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique())) throw codedError("INVALID_INTENT: chain not served");
    const existing = await ctx.db.query("intents").withIndex("by_tx", (q) => q.eq("chainId", chainId).eq("txHash", hash)).unique();
    if (existing) {
      if (existing.wallet !== w) throw codedError("INVALID_INTENT: transaction recorded by another wallet");
      return { id: existing._id, status: existing.status };
    }
    const now = Date.now();
    const id = await ctx.db.insert("intents", { wallet: w, chainId, txHash: hash, kind, ...(page ? { page } : {}), status: "pending", submittedAt: now, open: true, checkedAt: 0, updatedAt: now });
    await noteFirstSeen(ctx, w, now, "intent");
    return { id, status: "pending" as const };
  },
});

/** The signed-in wallet's latest intents, newest first, each with its explorer link. */
export const listForWallet = query({
  args: { wallet: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { wallet, limit }) => {
    const w = await requireWalletSession(ctx, wallet);
    const rows = await ctx.db
      .query("intents")
      .withIndex("by_wallet", (q) => q.eq("wallet", w))
      .order("desc")
      .take(Math.min(Math.max(Math.floor(limit ?? 20), 1), 100));
    const explorers = new Map((await ctx.db.query("deployments").collect()).map((d) => [d.chainId, explorerLinks(d.explorerUrl)]));
    return rows.map((r) => {
      const href = explorers.get(r.chainId)?.tx(r.txHash);
      return {
        chainId: r.chainId,
        txHash: r.txHash,
        kind: r.kind,
        ...(r.page ? { page: r.page } : {}),
        status: r.status,
        final: isFinal(r.status, r.finalizedAt),
        submittedAt: r.submittedAt,
        ...(r.blockNumber ? { blockNumber: r.blockNumber } : {}),
        ...(href ? { href } : {}),
        updatedAt: r.updatedAt,
      };
    });
  },
});

export const open = internalQuery({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => ctx.db.query("intents").withIndex("by_open", (q) => q.eq("chainId", chainId).eq("open", true)).order("asc").take(TRACK_BATCH),
});

export const isIndexed = internalQuery({
  args: { chainId: v.number(), txHash: v.string() },
  handler: async (ctx, { chainId, txHash }) => (await ctx.db.query("ingestedLogs").withIndex("by_tx", (q) => q.eq("txHash", txHash)).collect()).some((l) => l.chainId === chainId),
});

export const apply = internalMutation({
  args: {
    id: v.id("intents"),
    expected: v.string(),
    /** Null when the observation changed nothing: only the check time moves. */
    next: v.union(v.null(), v.object({ status: v.string(), blockNumber: v.optional(v.string()), blockHash: v.optional(v.string()), finalizedAt: v.optional(v.number()) })),
  },
  handler: async (ctx, { id, expected, next }) => {
    const row = await ctx.db.get(id);
    // Another run moved it first: its observation is as new as this one.
    if (!row || row.status !== expected) return;
    const now = Date.now();
    if (next === null) {
      await ctx.db.patch(id, { checkedAt: now });
      return;
    }
    const status = next.status as IntentStatus;
    const { _id, _creationTime, blockNumber: _b, blockHash: _h, finalizedAt: _f, ...rest } = row;
    await ctx.db.replace(id, { ...rest, ...next, status, open: !isFinal(status, next.finalizedAt), checkedAt: now, updatedAt: now });
  },
});

/** One tracker run for a chain: reads the receipt, the canonical hash of the stored block and finality per open intent. */
export const track = internalAction({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const intents = await ctx.runQuery(internal.intents.open, { chainId });
    if (intents.length === 0) return;
    const client = rpcClient(chainId);
    const finalized = await client.getBlock({ blockTag: "finalized" }).then((b) => b.number.toString(), () => null);
    for (const i of intents) {
      const receipt = await client.getTransactionReceipt({ hash: i.txHash as `0x${string}` }).then(
        (r) => ({ success: r.status === "success", blockNumber: r.blockNumber.toString(), blockHash: r.blockHash.toLowerCase() }),
        () => null,
      );
      const canonicalHash = i.blockNumber ? await client.getBlock({ blockNumber: BigInt(i.blockNumber) }).then((b) => b.hash?.toLowerCase() ?? null, () => null) : null;
      const indexed = await ctx.runQuery(internal.intents.isIndexed, { chainId, txHash: i.txHash });
      const state: IntentState = { status: i.status, submittedAt: i.submittedAt, ...(i.blockNumber ? { blockNumber: i.blockNumber } : {}), ...(i.blockHash ? { blockHash: i.blockHash } : {}), ...(i.finalizedAt !== undefined ? { finalizedAt: i.finalizedAt } : {}) };
      const next = nextIntentState(state, { receipt, canonicalHash, indexed, finalizedBlock: finalized, now: Date.now() });
      const { submittedAt: _s, ...fields } = next;
      await ctx.runMutation(internal.intents.apply, { id: i._id, expected: i.status, next: next === state ? null : fields });
    }
  },
});
