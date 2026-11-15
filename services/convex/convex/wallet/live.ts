// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Live reads: one wallet's accounts read at the chain head over Convex's RPC with Lens `getAccounts`, for clients
// that cannot read the chain themselves (Ask AI, server-rendered pages). The browser app reads the same view over
// its own RPC. Nothing is stored; each wallet may ask a bounded number of times a minute.

import { v } from "convex/values";
import { lensAbi } from "@avana/protocol/abis";
import { internal } from "../_generated/api";
import { action, internalQuery } from "../_generated/server";
import { type AccountSummary, type AccountViewLike, accountSummary } from "../lib/accounts.ts";
import { rpcClient } from "../lib/rpc.ts";

const PER_WALLET_PER_MINUTE = 30;
const ALL_PER_MINUTE = 1_200;
/** Markets one request reads at most; a wallet with more accounts is read in the order they were opened. */
const MAX_MARKETS = 32;

export const marketsOf = internalQuery({
  args: { chainId: v.number(), wallet: v.string() },
  handler: async (ctx, { chainId, wallet }) => {
    const rows = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", wallet)).collect();
    const ids = [...new Set(rows.filter((r) => r.chainId === chainId).map((r) => r.marketId))];
    const lens = (await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique())?.lens ?? null;
    return { lens, marketIds: ids.slice(0, MAX_MARKETS) };
  },
});

export type LiveAccounts = { readonly status: "ok"; readonly accounts: readonly AccountSummary[] } | { readonly status: "rateLimited" };

export const accounts = action({
  args: { chainId: v.number(), wallet: v.string(), marketIds: v.optional(v.array(v.string())) },
  handler: async (ctx, { chainId, wallet, marketIds }): Promise<LiveAccounts> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    if (marketIds && (marketIds.length > MAX_MARKETS || marketIds.some((m) => !/^\d{1,78}$/.test(m)))) throw new Error(`marketIds are up to ${MAX_MARKETS} decimal ids`);
    const w = wallet.toLowerCase();
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: "live:*", limit: ALL_PER_MINUTE }))) return { status: "rateLimited" };
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: `live:${w}`, limit: PER_WALLET_PER_MINUTE }))) return { status: "rateLimited" };
    const known = await ctx.runQuery(internal.wallet.live.marketsOf, { chainId, wallet: w });
    if (!known.lens) throw new Error(`chain ${chainId} is not served`);
    const ids = marketIds ?? known.marketIds;
    if (ids.length === 0) return { status: "ok", accounts: [] };
    const views = (await rpcClient(chainId).readContract({
      address: known.lens as `0x${string}`,
      abi: lensAbi,
      functionName: "getAccounts",
      args: [w as `0x${string}`, ids.map(BigInt)],
    })) as unknown as readonly AccountViewLike[];
    return { status: "ok", accounts: views.map(accountSummary) };
  },
});
