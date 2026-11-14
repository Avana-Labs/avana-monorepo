import { formatFixed } from "@/app/lib/borrow-system/model"
import type { TransactionPreview } from "@/app/lib/borrow-system/contracts"
import type { ActionPreviewUi, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { humanizeBlockedReason } from "@/app/lib/action-system/blocked-reason"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import {
  formatActionApproxUsd,
  formatActionAmount,
  formatActionBeforeAfter,
  formatActionFeeSummary,
  formatActionHealthFactor,
  formatActionInputAmount,
  formatActionPercent,
  formatActionPercentBeforeAfter,
  formatActionUsd,
  formatActionUsdBeforeAfter,
} from "@/app/lib/action-system/formatters"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

function hfToNumber(value: bigint | null) {
  // null = no debt → ∞. 0n = debt with zero liquidation value → underwater 0.
  if (value == null) return Number.POSITIVE_INFINITY
  return fixedToNumber(value, 18)
}

function hfTone(value: number | null): "default" | "positive" | "warning" | "danger" {
  if (value == null || !Number.isFinite(value)) return "positive"
  const tone = healthFactorBand(value).tone
  return tone === "default" ? "default" : tone
}

function riskFromPreview(preview: TransactionPreview, healthAfter: number) {
  const band = healthFactorBand(healthAfter)
  if (preview.riskLabel === "danger" || band.id === "danger") {
    return {
      level: "danger" as const,
      title: "This borrow puts your position at risk",
      message: `Health factor will drop to ${formatActionHealthFactor(healthAfter)} after this transaction. You are at risk of liquidation.`,
    }
  }
  if (preview.riskLabel === "warning" || band.id === "watch" || band.id === "moderate") {
    return {
      level: "warning" as const,
      title: "Borrowing gets tighter",
      message: `Health factor will be ${formatActionHealthFactor(healthAfter)} after this transaction.`,
    }
  }
  return null
}

// Collateral minus borrowed = position equity (surfaced in the UI as "Position
// equity"). A borrow adds equal debt and cash, so equity is unchanged — the label
// avoids reading like a borrow costs money.
function netBalanceUsd(preview: TransactionPreview, side: "before" | "after") {
  const snapshot = side === "before" ? preview.before : preview.after
  const collateral = fixedToNumber(snapshot.collateralValueUsd6, 6)
  const borrowed = fixedToNumber(snapshot.totalBorrowedUsd6, 6)
  return collateral - borrowed
}

function borrowingPowerUsd(preview: TransactionPreview, side: "before" | "after") {
  const snapshot = side === "before" ? preview.before : preview.after
  return fixedToNumber(snapshot.availableBorrowCapacityUsd6, 6)
}

function creditScopeMetric(scopeLabel?: string) {
  if (!scopeLabel) return []
  return [
    {
      id: "credit-scope",
      label: "Spoke",
      value: scopeLabel,
      tooltip: `Like an Aave v4 spoke, ${scopeLabel} pools credit: collateral anywhere in the spoke backs borrowing across it. Borrowing power, collateral and health below are for this spoke.`,
    },
  ]
}

// "in spoke" (Aave v4's term for the shared credit group); "in scope" read as jargon.
function scopedMetricLabel(label: string, scopeLabel?: string) {
  return scopeLabel ? `${label} in spoke` : label
}

export function mapBorrowTransactionPreviewToActionUi(
  preview: TransactionPreview,
  options: {
    symbol: string
    amountUsd: number
    marketLabel: string
    ratePct: number
    balanceLabel: string
    balanceUsd: number
    rateLabel?: string
    creditScopeLabel?: string
    liquidationThresholdPct?: number
    maxBorrowUsd?: number
    /** Live oracle price of the borrow asset. The amount the user types is a TOKEN
     * quantity, so the pill/review label and the Max amount are in tokens while the
     * engine (and amountUsd) stay in USD. Omitted -> falls back to USD-denominated. */
    priceUsd?: number
  },
): ActionPreviewUi {
  const price = options.priceUsd && options.priceUsd > 0 ? options.priceUsd : null
  const amountTokens = price ? options.amountUsd / price : options.amountUsd
  const beforeCollateral = fixedToNumber(preview.before.collateralValueUsd6, 6)
  const afterCollateral = fixedToNumber(preview.after.collateralValueUsd6, 6)
  const healthBefore = hfToNumber(preview.before.healthFactorWad)
  const healthAfter = hfToNumber(preview.after.healthFactorWad)
  const beforeApy = options.ratePct
  const afterApy = options.ratePct
  const beforeLtvPct = fixedToNumber(preview.before.currentLtvWad, 18) * 100
  const afterLtvPct = fixedToNumber(preview.after.currentLtvWad, 18) * 100
  // Max borrow is capped by the COLLATERAL FACTOR (available credit), never the
  // liquidation threshold — mirror the credit engine so Max lands at the safe cap.
  const maxBorrowUsd = options.maxBorrowUsd ?? borrowingPowerUsd(preview, "before")
  const rawBlockedReason = preview.validationErrors[0] ?? ""
  const limitingCondition = /liquidity/i.test(rawBlockedReason)
    ? "available market liquidity"
    : options.creditScopeLabel
      ? `borrowing power in ${options.creditScopeLabel}`
      : "available borrowing power"
  const blockedReason =
    !preview.allowed && options.amountUsd > maxBorrowUsd
      ? `Maximum safe borrow is ${formatActionUsd(maxBorrowUsd, { exact: true })}, limited by ${limitingCondition}.`
      : (humanizeBlockedReason(rawBlockedReason) ?? "Action unavailable")

  return {
    quoteId: preview.intent.id,
    allowed: preview.allowed,
    amountLabel: formatActionAmount(amountTokens, options.symbol),
    amountUsd: options.amountUsd,
    amountUsdLabel: formatActionApproxUsd(options.amountUsd),
    // The borrow rate is a simple-interest APR (baseBorrowAprWad / resolveBorrowAprPct), so label it
    // APR — matching the dashboard debt row — not APY.
    rateLabel: options.rateLabel ?? "Borrow APR",
    rateValue: formatActionPercent(options.ratePct),
    marketLabel: "Market",
    marketValue: options.marketLabel,
    balanceLabel: options.balanceLabel,
    balanceValue: formatActionUsd(options.balanceUsd),
    // Max is the borrow capacity expressed in the same TOKEN unit the user types.
    maxAmount: price ? maxBorrowUsd / price : maxBorrowUsd,
    metrics: [
      ...creditScopeMetric(options.creditScopeLabel),
      {
        id: "position-apy",
        label: "Position APY",
        value: formatActionPercentBeforeAfter(beforeApy, afterApy),
        before: formatActionPercent(beforeApy),
        after: formatActionPercent(afterApy),
      },
      {
        id: "ltv",
        label: scopedMetricLabel("LTV", options.creditScopeLabel),
        value: formatActionPercentBeforeAfter(beforeLtvPct, afterLtvPct),
        before: formatActionPercent(beforeLtvPct),
        after: formatActionPercent(afterLtvPct),
      },
      ...(options.liquidationThresholdPct != null
        ? [
            {
              id: "liquidation-threshold",
              label: "Liquidation threshold",
              value: formatActionPercent(options.liquidationThresholdPct),
            },
          ]
        : []),
      {
        id: "borrowing-power",
        label: scopedMetricLabel("Borrowing power", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(borrowingPowerUsd(preview, "before"), borrowingPowerUsd(preview, "after")),
        before: formatActionUsd(borrowingPowerUsd(preview, "before")),
        after: formatActionUsd(borrowingPowerUsd(preview, "after")),
      },
      {
        id: "net-balance",
        label: scopedMetricLabel("Position equity", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(netBalanceUsd(preview, "before"), netBalanceUsd(preview, "after")),
        before: formatActionUsd(netBalanceUsd(preview, "before")),
        after: formatActionUsd(netBalanceUsd(preview, "after")),
      },
      {
        id: "net-collateral",
        label: scopedMetricLabel("Net collateral", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(beforeCollateral, afterCollateral),
        before: formatActionUsd(beforeCollateral),
        after: formatActionUsd(afterCollateral),
      },
      {
        id: "health-factor",
        label: scopedMetricLabel("Health factor", options.creditScopeLabel),
        value: formatActionBeforeAfter(formatActionHealthFactor(healthBefore), formatActionHealthFactor(healthAfter)),
        before: formatActionHealthFactor(healthBefore),
        after: formatActionHealthFactor(healthAfter),
        tone: hfTone(healthAfter),
      },
    ],
    networkFeeLabel: formatActionFeeSummary(options.amountUsd, 0.04),
    risk: riskFromPreview(preview, healthAfter),
    blockedReason: preview.allowed ? null : blockedReason,
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapBorrowRepayPreviewToActionUi(
  preview: TransactionPreview,
  options: {
    symbol: string
    amountUsd: number
    marketLabel: string
    /** Token price used to express the repay input and Max in asset units. */
    priceUsd?: number
    remainingDebtUsd: number
    yearlyInterestSavedUsd: number
    creditScopeLabel?: string
    exceedsDebt?: boolean
  },
): ActionPreviewUi {
  const beforeDebt = fixedToNumber(preview.before.totalBorrowedUsd6, 6)
  const afterDebt = fixedToNumber(preview.after.totalBorrowedUsd6, 6)
  const healthBefore = hfToNumber(preview.before.healthFactorWad)
  const healthAfter = hfToNumber(preview.after.healthFactorWad)
  // Block over-debt repays here: the engine silently caps them instead of throwing, so an
  // inflated amount would otherwise reach the CTA and persist as the processed amount.
  const exceedsDebt = options.exceedsDebt ?? false
  const allowed = preview.allowed && !exceedsDebt
  const price = options.priceUsd && options.priceUsd > 0 ? options.priceUsd : null
  const amountTokens = price ? options.amountUsd / price : options.amountUsd

  return {
    quoteId: preview.intent.id,
    allowed,
    amountLabel: formatActionAmount(amountTokens, options.symbol),
    amountUsd: options.amountUsd,
    amountUsdLabel: formatActionApproxUsd(options.amountUsd),
    // In the debt token, like the amount typed; the USD equivalent sits under the input.
    rateLabel: "Repay amount",
    rateValue: formatActionAmount(amountTokens, options.symbol),
    marketLabel: "Market",
    marketValue: options.marketLabel,
    balanceLabel: "Outstanding debt",
    balanceValue: price
      ? formatActionAmount(beforeDebt / price, options.symbol, 4)
      : formatActionUsd(beforeDebt, { exact: true }),
    maxAmount: price ? beforeDebt / price : beforeDebt,
    metrics: [
      ...creditScopeMetric(options.creditScopeLabel),
      {
        id: "remaining-debt",
        label: "Remaining debt",
        value: formatActionUsdBeforeAfter(beforeDebt, afterDebt),
        before: formatActionUsd(beforeDebt),
        after: formatActionUsd(afterDebt),
      },
      {
        id: "health-factor",
        label: scopedMetricLabel("Health factor after", options.creditScopeLabel),
        value: formatActionBeforeAfter(formatActionHealthFactor(healthBefore), formatActionHealthFactor(healthAfter)),
        before: formatActionHealthFactor(healthBefore),
        after: formatActionHealthFactor(healthAfter),
        tone: hfTone(healthAfter),
      },
      {
        id: "interest-saved",
        label: "Interest saved (est. yearly)",
        value: formatActionUsd(options.yearlyInterestSavedUsd),
        tone: options.yearlyInterestSavedUsd > 0 ? "positive" : "default",
      },
    ],
    networkFeeLabel: formatActionFeeSummary(options.amountUsd, 0.04),
    risk: riskFromPreview(preview, healthAfter),
    blockedReason: allowed
      ? null
      : exceedsDebt
        ? `Amount exceeds outstanding debt. Maximum repay is ${price ? formatActionAmount(beforeDebt / price, options.symbol, 4) : formatActionUsd(beforeDebt, { exact: true })}.`
        : (humanizeBlockedReason(preview.validationErrors[0]) ?? "Action unavailable"),
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapBorrowSupplyPreviewToActionUi(
  preview: TransactionPreview,
  options: {
    symbol: string
    amountUsd: number
    marketLabel: string
    poolLabel: string
    collateralSymbol: string
    borrowSymbol: string
    collateralFactorPct: number
    collateralRiskPct: number
    borrowableAssetsLabel: string
    borrowableAssetSymbols: string[]
    creditScopeLabel?: string
    walletBalanceUsd?: number
  },
): ActionPreviewUi {
  const borrowPowerBefore = borrowingPowerUsd(preview, "before")
  const borrowPowerAfter = borrowingPowerUsd(preview, "after")
  const healthBefore = hfToNumber(preview.before.healthFactorWad)
  const healthAfter = hfToNumber(preview.after.healthFactorWad)
  const maxPledgeUsd = options.walletBalanceUsd ?? 0
  const exceedsBalance = maxPledgeUsd > 0 && options.amountUsd > maxPledgeUsd
  const blockedReason = preview.allowed
    ? exceedsBalance
      ? `Maximum pledge is ${formatActionUsd(maxPledgeUsd, { exact: true })}, limited by wallet LP balance.`
      : null
    : exceedsBalance
      ? `Maximum pledge is ${formatActionUsd(maxPledgeUsd, { exact: true })}, limited by wallet LP balance.`
      : (humanizeBlockedReason(preview.validationErrors[0]) ?? "Action unavailable")

  return {
    quoteId: preview.intent.id,
    allowed: preview.allowed && !exceedsBalance,
    amountLabel: formatActionUsd(options.amountUsd),
    amountValue: formatActionInputAmount(options.amountUsd, 2),
    assetLabel: options.poolLabel,
    assetSymbol: options.collateralSymbol,
    borrowSymbol: options.borrowSymbol,
    amountUsd: options.amountUsd,
    amountUsdLabel: formatActionApproxUsd(options.amountUsd),
    rateLabel: "Collateral factor",
    rateValue: formatActionPercent(options.collateralFactorPct),
    marketLabel: "Market",
    marketValue: options.marketLabel,
    balanceLabel: maxPledgeUsd > 0 ? "Wallet balance" : "Borrow power",
    balanceValue: maxPledgeUsd > 0 ? formatActionUsd(maxPledgeUsd) : formatActionUsd(borrowPowerAfter),
    maxAmount: maxPledgeUsd > 0 ? maxPledgeUsd : null,
    metrics: [
      ...creditScopeMetric(options.creditScopeLabel),
      {
        id: "collateral-factor",
        label: "Collateral factor",
        value: formatActionPercent(options.collateralFactorPct),
      },
      {
        id: "collateral-risk",
        label: "Collateral risk",
        value: formatActionPercent(options.collateralRiskPct),
        tone: options.collateralRiskPct > 15 ? "warning" : "default",
      },
      {
        id: "borrowable-assets",
        label: "Borrowable assets",
        value: options.borrowableAssetsLabel,
        tokenSymbols: options.borrowableAssetSymbols,
      },
      {
        id: "borrow-power",
        label: scopedMetricLabel("Borrowing power", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(borrowPowerBefore, borrowPowerAfter),
        before: formatActionUsd(borrowPowerBefore),
        after: formatActionUsd(borrowPowerAfter),
      },
      {
        id: "hf",
        label: scopedMetricLabel("Health factor", options.creditScopeLabel),
        value: formatActionBeforeAfter(formatActionHealthFactor(healthBefore), formatActionHealthFactor(healthAfter)),
        before: formatActionHealthFactor(healthBefore),
        after: formatActionHealthFactor(healthAfter),
        tone: hfTone(healthAfter),
      },
    ],
    networkFeeLabel: formatActionFeeSummary(options.amountUsd, 0.04),
    risk: null,
    blockedReason,
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapBorrowRemovePreviewToActionUi(
  preview: TransactionPreview,
  options: {
    percent: number
    safePercent: number
    removeUsd: number
    marketLabel: string
    positionApyPct: number
    creditScopeLabel?: string
  },
): ActionPreviewUi {
  const beforeCollateral = fixedToNumber(preview.before.collateralValueUsd6, 6)
  const afterCollateral = fixedToNumber(preview.after.collateralValueUsd6, 6)
  // Blocked simulations keep `after` equal to `before`, so the state delta would render an
  // unsafe request as $0.00. Blocked previews use the requested amount instead.
  const simulatedRemoveUsd = Math.max(0, beforeCollateral - afterCollateral)
  const removeUsd = preview.allowed ? simulatedRemoveUsd : Math.max(0, options.removeUsd)
  const annualBefore = (beforeCollateral * options.positionApyPct) / 100
  const annualAfter = (afterCollateral * options.positionApyPct) / 100
  const healthBefore = hfToNumber(preview.before.healthFactorWad)
  const healthAfter = hfToNumber(preview.after.healthFactorWad)

  return {
    quoteId: preview.intent.id,
    allowed: preview.allowed,
    amountLabel: `${options.percent}%`,
    amountValue: String(options.percent),
    amountUnitLabel: "%",
    assetLabel: "%",
    assetSymbol: "%",
    amountUsd: removeUsd,
    amountUsdLabel: formatActionUsd(removeUsd, { exact: true }),
    rateLabel: "Position APY",
    rateValue: formatActionPercent(options.positionApyPct),
    marketLabel: "Market",
    marketValue: options.marketLabel,
    balanceLabel: "Removing",
    balanceValue: formatActionUsd(removeUsd, { exact: true }),
    maxAmount: options.safePercent,
    metrics: [
      ...creditScopeMetric(options.creditScopeLabel),
      {
        id: "annual-earnings",
        label: "Annual earnings",
        value: formatActionUsdBeforeAfter(annualBefore, annualAfter),
        before: formatActionUsd(annualBefore),
        after: formatActionUsd(annualAfter),
      },
      {
        id: "borrowing-power",
        label: scopedMetricLabel("Borrowing power", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(borrowingPowerUsd(preview, "before"), borrowingPowerUsd(preview, "after")),
        before: formatActionUsd(borrowingPowerUsd(preview, "before")),
        after: formatActionUsd(borrowingPowerUsd(preview, "after")),
      },
      {
        id: "net-balance",
        label: scopedMetricLabel("Position equity", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(netBalanceUsd(preview, "before"), netBalanceUsd(preview, "after")),
        before: formatActionUsd(netBalanceUsd(preview, "before")),
        after: formatActionUsd(netBalanceUsd(preview, "after")),
      },
      {
        id: "net-collateral",
        label: scopedMetricLabel("Net collateral", options.creditScopeLabel),
        value: formatActionUsdBeforeAfter(beforeCollateral, afterCollateral),
        before: formatActionUsd(beforeCollateral),
        after: formatActionUsd(afterCollateral),
      },
      {
        id: "hf",
        label: scopedMetricLabel("Health factor", options.creditScopeLabel),
        value: formatActionBeforeAfter(formatActionHealthFactor(healthBefore), formatActionHealthFactor(healthAfter)),
        before: formatActionHealthFactor(healthBefore),
        after: formatActionHealthFactor(healthAfter),
        tone: hfTone(healthAfter),
      },
    ],
    networkFeeLabel: formatActionFeeSummary(removeUsd, 0.04),
    risk: riskFromPreview(preview, hfToNumber(preview.after.healthFactorWad)),
    blockedReason: preview.allowed
      ? null
      : (humanizeBlockedReason(preview.validationErrors[0]) ?? "Action unavailable"),
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapBorrowSuccessToActionUi(options: {
  title: string
  description: string
  receiptHash: string | null
  metrics: ActionPreviewUi["metrics"]
  href: string
  primaryCtaLabel?: string
  preview?: Pick<
    ActionPreviewUi,
    "quoteId" | "amountLabel" | "amountUsd" | "rateLabel" | "rateValue" | "marketValue"
  > | null
  verb?: string
}): ActionSuccessUi {
  return {
    quoteId: options.preview?.quoteId,
    title: options.title,
    description: options.description,
    receiptHash: options.receiptHash,
    metrics: options.metrics,
    primaryCtaLabel: options.primaryCtaLabel ?? "View dashboard",
    primaryCtaHref: options.href,
    secondaryCtaLabel: "Done",
    receiptContext: options.preview
      ? {
          verb: options.verb ?? "Action",
          amountUsd: options.preview.amountUsd,
          amountLabel: options.preview.amountLabel,
          rateLabel: options.preview.rateLabel,
          rateValue: options.preview.rateValue,
          marketValue: options.preview.marketValue,
        }
      : undefined,
  }
}
