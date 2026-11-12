// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Loads a listing's metadata once its timelock operation executes: fetches `<LISTING_CONTENT_URL>/<salt>.json`,
// checks that keccak256 of the bytes equals the operation's salt and stores every entry. A missing file means the
// operation carried no metadata; a file that fails the hash or the structure check is refused and recorded.

import { v } from "convex/values";
import { requireEnv } from "@avana/services-common/env";
import { internal } from "../_generated/api";
import { internalAction, internalQuery } from "../_generated/server";
import { MetadataRejected, parseMetadata } from "../lib/metadata.ts";

export const operation = internalQuery({
  args: { chainId: v.number(), operationId: v.string() },
  handler: async (ctx, a) => ctx.db.query("listingOperations").withIndex("by_op", (q) => q.eq("chainId", a.chainId).eq("operationId", a.operationId)).unique(),
});

export const loadMetadata = internalAction({
  args: { chainId: v.number(), operationId: v.string() },
  handler: async (ctx, { chainId, operationId }): Promise<void> => {
    const op = await ctx.runQuery(internal.listing.load.operation, { chainId, operationId });
    if (!op || op.status !== "executed") return;
    const res = await fetch(`${requireEnv(process.env, "LISTING_CONTENT_URL").replace(/\/$/, "")}/${op.salt}.json`);
    if (res.status === 404) {
      await ctx.runMutation(internal.listing.store.mark, { chainId, operationId, status: "noMetadata" });
      return;
    }
    if (!res.ok) throw new Error(`listing content for ${op.salt} answered ${res.status}`);
    try {
      const file = parseMetadata(new Uint8Array(await res.arrayBuffer()), op.salt, chainId);
      await ctx.runMutation(internal.listing.store.store, { chainId, operationId, contentHash: op.salt, entries: file.entries });
    } catch (e) {
      if (!(e instanceof MetadataRejected)) throw e;
      console.error(`listing ${operationId}: ${e.message}`);
      await ctx.runMutation(internal.listing.store.mark, { chainId, operationId, status: "rejected", error: e.message });
    }
  },
});
