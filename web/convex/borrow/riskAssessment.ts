/** Borrow product — Risk Premium / assessment card. Table: `borrowRiskAssessments`. */

import { defineRiskAssessmentModule } from "../silo/riskAssessment"

export const { readRisk, getRisk, upsertRiskAssessments } = defineRiskAssessmentModule("borrowRiskAssessments", {
  withKind: true,
})
