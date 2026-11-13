// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One query for every chart: the points of one metric of one scope, hourly for the last 30 days or daily, gaps
// filled, each with the block it was read at. Values stay in the scope's units (base units, RAY, 8-decimal USD).

import { v } from "convex/values";
import { RESOLUTION_SECONDS } from "@avana/services-common/series";
import { query } from "./_generated/server";
import { combineSources, filledBuckets } from "./lib/charts.ts";
import { scopePoints } from "./model.ts";

const kind = v.union(v.literal("hubAsset"), v.literal("hubAssetSpoke"), v.literal("market"), v.literal("marketReserve"), v.literal("pool"), v.literal("position"));

export const get = query({
  args: { scopeKind: kind, scopeKey: v.string(), metric: v.string(), resolution: v.union(v.literal("hour"), v.literal("day")), days: v.optional(v.number()) },
  handler: async (ctx, { scopeKind, scopeKey, metric, resolution, days }) => {
    const now = Math.floor(Date.now() / 1000);
    const span = Math.min(days ?? (resolution === "hour" ? 7 : 365), resolution === "hour" ? 30 : 3_650);
    const from = now - span * RESOLUTION_SECONDS.day;
    const stored = await scopePoints(ctx, scopeKind, scopeKey.toLowerCase(), resolution, from - RESOLUTION_SECONDS[resolution] * 48);
    const filled = filledBuckets(scopeKind, combineSources(scopeKind, stored), from, now, resolution);
    return { points: filled.filter((p) => p.values[metric] !== undefined).map((p) => ({ t: p.t * 1000, v: p.values[metric]! })) };
  },
});
