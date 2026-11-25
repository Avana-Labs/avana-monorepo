// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Editorial content of a page by slug, as loaded from the listing metadata.

import { v } from "convex/values";
import { query } from "./_generated/server";

export const get = query({
  args: { scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool"), v.literal("spoke"), v.literal("token"), v.literal("hub")), slug: v.string() },
  handler: async (ctx, { scope, slug }) => ctx.db.query("marketContent").withIndex("by_slug", (q) => q.eq("scope", scope).eq("slug", slug)).unique(),
});
