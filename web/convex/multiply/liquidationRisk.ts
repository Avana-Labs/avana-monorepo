/** Multiply product — Liquidation Risk KPIs. Table: `multiplyLiquidationDaily`. */

import { defineLiquidationRiskModule } from "../silo/liquidationRisk"

export const { readLiquidationRisk, getLiquidationRisk, upsertLiquidationDaily } =
  defineLiquidationRiskModule("multiplyLiquidationDaily")
