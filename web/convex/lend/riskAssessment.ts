/** Lend product — Risk Premium / assessment card. Table: `lendRiskAssessments`. */

import { defineRiskAssessmentModule } from "../silo/riskAssessment"

export const { readRisk, getRisk, upsertRiskAssessments } = defineRiskAssessmentModule("lendRiskAssessments")
