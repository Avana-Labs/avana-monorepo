import type { RiskAssessment } from "@/app/lib/borrow-detail"

/**
 * Neutral, data-free risk assessment — the live-mode fail-closed value for the shared
 * RiskSection when Convex has no risk row for a market. Renders as a 0-score / 0-bps card
 * with no breakdown or metrics: an honest "no assessment on file" state, never a mock
 * fixture. Shared by the borrow, lend and multiply detail builders so all three degrade
 * identically instead of silently reusing their catalog risk copy.
 */
export const EMPTY_RISK_ASSESSMENT: RiskAssessment = {
  premiumBps: 0,
  level: "low",
  score: 0,
  headline: "",
  summary: "",
  breakdown: [],
  metrics: [],
}
