// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A newly listed pool's history before its listing block, so its charts start with data: ranges of the indexer's
// pool-history endpoint from `POOL_HISTORY_DAYS` (default 90) before the listing to the block before it, applied
// in order, each once.

import { v } from "convex/values";
import { chainById } from "@avana/services-common/chains";
import { optionalEnv } from "@avana/services-common/env";
import type { SeriesRecord } from "@avana/services-common/series";
import { internal } from "../_generated/api";
import { internalAction } from "../_generated/server";
import { exportGet } from "./pull.ts";

/** Blocks per request; the endpoint accepts up to 50,000. */
const RANGE = 10_000n;

export const backfill = internalAction({
  args: { chainId: v.number(), pool: v.string(), listedBlock: v.string() },
  handler: async (ctx, { chainId, pool, listedBlock }) => {
    const days = BigInt(optionalEnv(process.env, "POOL_HISTORY_DAYS") ?? "90");
    const perDay = 86_400n / BigInt(chainById(chainId).blockTimeSeconds);
    const listed = BigInt(listedBlock);
    const start = listed > days * perDay ? listed - days * perDay : 0n;
    const progress = await ctx.runMutation(internal.ingest.apply.poolBackfill, { chainId, pool, fromBlock: start.toString(), listedBlock });
    for (let from = BigInt(progress.throughBlock) + 1n; from < listed; ) {
      const to = from + RANGE - 1n < listed - 1n ? from + RANGE - 1n : listed - 1n;
      const body = await exportGet<{ records: SeriesRecord[] }>(`/export/v1/pool-history?chainId=${chainId}&pool=${pool}&fromBlock=${from}&toBlock=${to}`);
      if (!body) return;
      const { applied } = await ctx.runMutation(internal.ingest.apply.applyPoolHistory, { chainId, pool, fromBlock: from.toString(), toBlock: to.toString(), records: body.records });
      if (!applied) return; // another run is ahead
      from = to + 1n;
    }
  },
});
