/** Multiply product — Risk Parameters. Table: `multiplyRiskParameters`. */

import { defineRiskParametersModule } from "../silo/riskParameters"

export const { readRiskParameters, getRiskParameters, upsertRiskParameters } =
  defineRiskParametersModule("multiplyRiskParameters")
