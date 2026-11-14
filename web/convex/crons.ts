/**
 * Scheduled jobs.
 *   - refresh token prices from DefiLlama every 10 minutes so the sandbox "Price" tracks
 *     production and staleness surfaces within ~20m of a wedged cron (the batched request is cheap).
 *   - roll up daily market stats near end-of-day UTC: flush the running liquidity
 *     delta into a persistent `marketDailyStats` snapshot so the chart series grows
 *     over calendar time with real activity (seed = starting history only).
 *   - liquidity aggregate rebuild + compaction are ACTION-TRIGGERED (see `convex/liquidity.ts`),
 *     not interval crons — idle hours must not burn scheduled executions.
 */

import { cronJobs } from "convex/server"
import { internal } from "./_generated/api"

const crons = cronJobs()

crons.interval("refresh token prices", { minutes: 10 }, internal.prices.refreshPrices, {})
crons.daily("snapshot daily token prices", { hourUTC: 23, minuteUTC: 58 }, internal.prices.snapshotDailyTokenPrices, {})
// FX moves slowly (daily provider updates); hourly keeps the validated fiat layer fresh cheaply.
crons.interval("refresh fx rates", { hours: 1 }, internal.fx.refreshFxRates, {})
// Flush each market's running liquidity delta into a persistent daily snapshot near
// end-of-day UTC, so the chart series lengthens over calendar time with real activity
// (the seed is just the starting history). See `markets.rollupDailyStats`.
crons.daily("roll up daily market stats", { hourUTC: 23, minuteUTC: 55 }, internal.markets.rollupDailyStats, {})

// Ask AI market ingestion — refresh the server-side cache (`askAIMarketSnapshots`) that Ask AI's
// tools read. Ask AI never calls these providers per user request; it only reads this cache.
// Each source runs on its own staggered schedule so one provider's failure/429 cannot delay the
// others. DefiLlama covers token prices + cross-protocol pool data (Uniswap/Curve/Balancer/…);
// Aave covers lending markets via its public keyless v3 API.
crons.cron("ask ai ingest defillama pools", "3 * * * *", internal.askAIIngestion.ingest, {
  source: "defillama",
})
crons.cron("ask ai ingest aave markets", "9,39 * * * *", internal.askAIIngestion.ingest, { source: "aave" })

export default crons
