/** Multiply product — Risk Premium / assessment card. Table: `multiplyRiskAssessments`. */

import { defineRiskAssessmentModule } from "../silo/riskAssessment"

export const { readRisk, getRisk, upsertRiskAssessments } = defineRiskAssessmentModule("multiplyRiskAssessments")
