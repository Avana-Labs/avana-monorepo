// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Schedules: current values every 30 s per chain, the export pull every 30 s on Ethereum and 10 s on Base, and the
// 30-day log retention daily. Chains are those with a `deployments` row; a chain without one is skipped.

import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

for (const chainId of [1, 8453]) {
  crons.interval(`sample current values ${chainId}`, { seconds: 30 }, internal.ingest.sampler.refresh, { chainId });
  crons.interval(`pull export ${chainId}`, { seconds: chainId === 1 ? 30 : 10 }, internal.ingest.pull.pull, { chainId });
}
crons.daily("prune activity older than 30 days", { hourUTC: 3, minuteUTC: 0 }, internal.ingest.apply.prune, {});

export default crons;
