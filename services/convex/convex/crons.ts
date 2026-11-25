// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Schedules: current values and the export pull every 60 s per chain, and the 30-day log retention daily; expired
// SIWE sessions daily; the previous UTC day's liquidation and revenue rollups at 00:30; Merkl incentives and market
// risk scores hourly; every 5 minutes a check that each chain with open transaction intents has its tracker running
// (the tracker itself runs about once a block only while intents are open, intents.ts). Chains are those with a
// `deployments` row; a chain without one is skipped. The app features add: off-protocol token prices every 10 minutes
// (and a daily close), FX hourly, and the Ask AI market cache (DefiLlama pools hourly, Aave markets twice an hour).
// The per-chain jobs run on the chains of AVANA_CHAIN_IDS (lib/cronChains.ts). A deployment without AVANA_CHAIN_IDS (a
// development deployment) schedules no cron at all.

import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";
import { cronChains } from "./lib/cronChains";

const crons = cronJobs();
const chains = cronChains(process.env);

for (const { chainId, sampleSeconds, pullSeconds, merklCron } of chains) {
  crons.interval(`sample current values ${chainId}`, { seconds: sampleSeconds }, internal.ingest.sampler.refresh, { chainId });
  crons.interval(`pull export ${chainId}`, { seconds: pullSeconds }, internal.ingest.pull.pull, { chainId });
  crons.cron(`refresh merkl incentives ${chainId}`, merklCron, internal.incentives.refresh, { chainId });
}
if (chains.length > 0) {
  crons.interval("wake intent trackers", { minutes: 5 }, internal.intents.wake, {});
  crons.daily("prune activity older than 30 days", { hourUTC: 3, minuteUTC: 0 }, internal.ingest.apply.prune, {});
  crons.cron("score market risk", "5 * * * *", internal.riskScores.score, {});
  crons.daily("roll up liquidations and revenue", { hourUTC: 0, minuteUTC: 30 }, internal.rollups.rollUp, {});
  crons.daily("prune expired SIWE sessions", { hourUTC: 3, minuteUTC: 20 }, internal.siweSessions.prune, {});

  crons.interval("refresh token prices", { minutes: 10 }, internal.tokenPrices.refreshPrices, {});
  crons.daily("snapshot daily token prices", { hourUTC: 23, minuteUTC: 58 }, internal.tokenPrices.snapshotDailyTokenPrices, {});
  crons.interval("refresh fx rates", { hours: 1 }, internal.fx.refreshFxRates, {});
  crons.cron("ask ai ingest defillama pools", "3 * * * *", internal.askAIIngestion.ingest, { source: "defillama" });
  crons.cron("ask ai ingest aave markets", "9,39 * * * *", internal.askAIIngestion.ingest, { source: "aave" });
}

export default crons;
