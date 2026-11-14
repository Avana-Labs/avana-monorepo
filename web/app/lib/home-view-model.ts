// View-model types and formatters of the Express (home) card. The card reads markets and
// wallet positions from the session; there are no built-in pools, tokens or previews.
import { getActiveCurrency } from "@/app/lib/currency/active-rate"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"

export type HomeMode = "borrow" | "swap" | "repay" | "claim" | "remove"

export type HomeAssetVisual = {
  symbol: string
  shortLabel: string
  bgClassName: string
  textClassName: string
}

export type HomeCollateralPool = {
  id: string
  name: string
  venue: string
  category: string
  collateralUsd: number
  /** This pool's own pledged LP; `collateralUsd` is the credit shared across its group. */
  ownCollateralUsd?: number
  maxLtv: number
  borrowPowerUsd: number
  liquidationUsd: number
  pairApr: number
  visuals: [HomeAssetVisual, HomeAssetVisual]
}

export type HomeBorrowToken = {
  id: string
  name: string
  symbol: string
  subtitle: string
  borrowApr: number
  visual: HomeAssetVisual
}

export type HomeClaimBreakdown = {
  id: string
  symbol: string
  amountLabel: string
  usdValue: number
  visual: HomeAssetVisual
}

export type HomeClaimPosition = {
  id: string
  poolId: string
  name: string
  subtitle: string
  totalUsd: number
  breakdown: HomeClaimBreakdown[]
}

export type HomeSuccessRowTone = "default" | "positive" | "warning" | "danger"

export type HomeSuccessRow = {
  label: string
  value: string
  tone?: HomeSuccessRowTone
}

export type HomeRiskTone = "neutral" | "positive" | "warning" | "danger"

export type BorrowPreview = {
  amountUsd: number
  amountLabel: string
  isEmpty: boolean
  isValid: boolean
  exceedsBorrowPower: boolean
  healthFactor: number | null
  healthFactorLabel: string
  riskTone: HomeRiskTone
  progressPercent: number
  remainingBorrowPowerUsd: number
  warningTitle: string | null
  warningMessage: string | null
  ctaLabel: string
}

export type RepayPreview = {
  amountUsd: number
  isEmpty: boolean
  isValid: boolean
  exceedsDebt: boolean
  remainingDebtUsd: number
  remainingDebtLabel: string
  healthFactorAfter: number | null
  healthFactorAfterLabel: string
  oldHealthFactorLabel: string
  riskTone: HomeRiskTone
  yearlyInterestSavedUsd: number
  ctaLabel: string
}

export type ClaimPreview = {
  selectedPositionIds: string[]
  selectedTotalUsd: number
  effectiveClaimUsd: number
  hasSelection: boolean
  hasCustomAmount: boolean
  ctaLabel: string
  helperLabel: string
  tokenTotals: Record<string, number>
}

export type RemovePreview = {
  percent: number
  safePercent: number
  removeUsd: number
  afterCollateralUsd: number
  healthFactorAfter: number | null
  healthFactorAfterLabel: string
  riskTone: HomeRiskTone
  isUnsafe: boolean
  isValid: boolean
  liquidationThresholdAfterUsd: number
  ctaLabel: string
}

export function formatUsd(value: number) {
  // Currency-aware (matches the sibling formatCompactUsd and the header switcher);
  // previously hardcoded "$", so "Claim $X in fees" stayed USD under EUR/etc.
  const { symbol, rate } = getActiveCurrency()
  const converted = value * rate
  return `${symbol}${converted.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

export function formatCompactUsd(usdValue: number) {
  const { symbol, rate } = getActiveCurrency()
  const value = usdValue * rate
  return `${symbol}${value.toLocaleString("en-US", { maximumFractionDigits: value >= 100 ? 0 : 2 })}`
}

// A position whose debt is a rounding-dust fraction of its collateral produces a
// mathematically-finite but meaninglessly-large health factor (e.g. 18369.7).
// Treat anything at or above this as effectively infinite so the display reads "∞"
// consistently instead of an alarming raw number.
const HEALTH_FACTOR_INFINITE_THRESHOLD = 1_000

export function formatHealthFactor(value: number | null) {
  if (value === null || Number.isNaN(value)) {
    return "—"
  }

  if (!Number.isFinite(value) || value >= HEALTH_FACTOR_INFINITE_THRESHOLD) {
    return "∞"
  }

  return value.toFixed(2)
}

export function getRiskTone(healthFactor: number | null): HomeRiskTone {
  const band = healthFactorBand(healthFactor)
  if (band.id === "unknown") return "neutral"
  if (band.tone === "positive") return "positive"
  if (band.tone === "danger") return "danger"
  return "warning"
}

type HealthStatus = {
  label: string
  dotClass: string
  textClass: string
  barClass: string
}

export function getHealthStatus(hf: number): HealthStatus {
  const band = healthFactorBand(hf)
  return {
    label: band.label.toUpperCase(),
    dotClass: band.status.dotClass,
    textClass: band.status.textClass,
    barClass: band.status.barClass,
  }
}

/** Totals of the selected fee-claim positions (pure arithmetic over the selection). */
export function calculateClaimPreview(
  positions: HomeClaimPosition[],
  claimableTotals: Record<string, number>,
  selections: Record<string, boolean>,
  partialAmountUsd: number | null,
): ClaimPreview {
  const selectedPositionIds = positions.filter((position) => selections[position.id]).map((position) => position.id)
  const selectedTotalUsd = selectedPositionIds.reduce((sum, positionId) => sum + (claimableTotals[positionId] ?? 0), 0)
  const hasCustomAmount = partialAmountUsd !== null && partialAmountUsd > 0
  const effectiveClaimUsd = hasCustomAmount ? Math.min(partialAmountUsd ?? 0, selectedTotalUsd) : selectedTotalUsd
  // Claim breakdown is token harvest only — never list "Fees" as a green claimable
  // reward leg beside ETH/USDC (that confused fee cost with rewards).
  const tokenTotals = positions.reduce<Record<string, number>>((accumulator, position) => {
    if (!selections[position.id]) {
      return accumulator
    }

    position.breakdown.forEach((item) => {
      if (item.symbol === "Fees") return
      accumulator[item.symbol] = (accumulator[item.symbol] ?? 0) + item.usdValue
    })

    return accumulator
  }, {})

  return {
    selectedPositionIds,
    selectedTotalUsd,
    effectiveClaimUsd,
    hasSelection: selectedPositionIds.length > 0,
    hasCustomAmount,
    ctaLabel:
      selectedPositionIds.length > 0 ? `Claim ${formatUsd(effectiveClaimUsd)} in fees` : "Select positions to claim",
    helperLabel: hasCustomAmount ? "Partial claim from selected positions" : "Leave empty to claim all selected",
    tokenTotals,
  }
}
