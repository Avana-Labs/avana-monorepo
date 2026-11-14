// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Schedules: current values every 30 s per chain, the export pull every 30 s on Ethereum and 10 s on Base, and the
// 30-day log retention daily. Chains are those with a `deployments` row; a chain without one is skipped. The app
// features add: off-protocol token prices every 10 minutes (and a daily close), FX hourly, and the Ask AI market
// cache (DefiLlama pools hourly, Aave markets twice an hour).

import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

for (const chainId of [1, 8453]) {
  crons.interval(`sample current values ${chainId}`, { seconds: 30 }, internal.ingest.sampler.refresh, { chainId });
  crons.interval(`pull export ${chainId}`, { seconds: chainId === 1 ? 30 : 10 }, internal.ingest.pull.pull, { chainId });
}
crons.daily("prune activity older than 30 days", { hourUTC: 3, minuteUTC: 0 }, internal.ingest.apply.prune, {});

crons.interval("refresh token prices", { minutes: 10 }, internal.tokenPrices.refreshPrices, {});
crons.daily("snapshot daily token prices", { hourUTC: 23, minuteUTC: 58 }, internal.tokenPrices.snapshotDailyTokenPrices, {});
crons.interval("refresh fx rates", { hours: 1 }, internal.fx.refreshFxRates, {});
crons.cron("ask ai ingest defillama pools", "3 * * * *", internal.askAIIngestion.ingest, { source: "defillama" });
crons.cron("ask ai ingest aave markets", "9,39 * * * *", internal.askAIIngestion.ingest, { source: "aave" });

export default crons;
