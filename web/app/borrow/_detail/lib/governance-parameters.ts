/**
 * UI-facing re-exports for risk / governance parameter normalization.
 * Canonical helpers live in `@/app/lib/borrow-detail/risk-parameters`.
 */
export {
  RISK_PARAMETER_LABELS,
  buildRiskParameterSet,
  normalizeGovernanceParameters,
  withEngineLiquidationThreshold,
  withGovernanceParameterView,
} from "@/app/lib/borrow-detail/risk-parameters"
