/** Lend product — daily market stats. Table: `lendDailyStats`. */

import { defineDailyStatsModule } from "../silo/dailyStats"

export const { getLatestStats, upsertDailyStats } = defineDailyStatsModule("lendDailyStats", {
  identity: () => ({}),
})
