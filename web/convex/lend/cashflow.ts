/** Lend product — Cashflow. Table: `lendRevenueDaily`. */

import { defineCashflowModule } from "../silo/cashflow"

export const { getBreakdown, upsertRevenueDaily } = defineCashflowModule("lendRevenueDaily", { scope: "lend" })
