/** Lend product — Risk Parameters. Table: `lendRiskParameters`. */

import { defineRiskParametersModule } from "../silo/riskParameters"

export const { readRiskParameters, getRiskParameters, upsertRiskParameters } =
  defineRiskParametersModule("lendRiskParameters")
