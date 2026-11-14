/** Multiply product — Cashflow. Table: `multiplyRevenueDaily`. */

import { defineCashflowModule } from "../silo/cashflow"

export const { getBreakdown, upsertRevenueDaily } = defineCashflowModule("multiplyRevenueDaily", { scope: "multiply" })
