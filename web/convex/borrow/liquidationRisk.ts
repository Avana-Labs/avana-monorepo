/** Borrow product — Liquidation Risk KPIs. Table: `borrowLiquidationDaily`. */

import { defineLiquidationRiskModule } from "../silo/liquidationRisk"

export const { readLiquidationRisk, getLiquidationRisk, upsertLiquidationDaily } =
  defineLiquidationRiskModule("borrowLiquidationDaily")
