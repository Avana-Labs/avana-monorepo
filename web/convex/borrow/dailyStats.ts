/** Borrow product — daily market stats (pool + asset). Table: `borrowDailyStats`. */

import { defineDailyStatsModule } from "../silo/dailyStats"

export const { getLatestStats, upsertDailyStats } = defineDailyStatsModule("borrowDailyStats", {
  withKind: true,
  identity: (row) => ({ kind: row.kind }),
})
