import type { MultiplyTransactionPreview } from "@/app/lib/multiply-system/contracts"
import type { ActionMetricTone, ActionPreviewUi } from "@/app/lib/action-system/contracts"
import {
  formatActionApproxUsd,
  formatActionAmount,
  formatActionBeforeAfter,
  formatActionHealthFactor,
  formatActionFeeSummary,
  formatActionRatioPercent,
  formatActionUsd,
} from "@/app/lib/action-system/formatters"
import { HEALTH_BANDS } from "@/app/lib/health/health-factor-bands"

// Near the 1.0 liquidation floor there is almost no safety buffer, so this reads as
// danger (a firm "Risk of liquidation"), not a soft caution. Single-sourced from the
// shared danger band (hf < 1.2) so the red HF bar and this banner fire together
// rather than at different thresholds.
const NEAR_LIQUIDATION_HF = HEALTH_BANDS.find((band) => band.id === "danger")?.max ?? 1.2

function hfTone(value: number) {
  if (!Number.isFinite(value)) return "positive" as const
  if (value < NEAR_LIQUIDATION_HF) return "danger" as const
  if (value < 1.5) return "warning" as const
  return "positive" as const
}

function hfNumber(value: number | "infinity") {
  return value === "infinity" ? Number.POSITIVE_INFINITY : value
}

function metricBeforeAfter(id: string, label: string, before: string, after: string, tone?: ActionMetricTone) {
  return {
    id,
    label,
    value: formatActionBeforeAfter(before, after),
    before,
    after,
    tone,
  }
}

function metricValue(id: string, label: string, value: string, tone?: ActionMetricTone) {
  return {
    id,
    label,
    value,
    tone,
  }
}

function addedValue(after: number, before: number) {
  return Math.max(0, after - before)
}

export function mapMultiplyPreviewToActionUi(
  preview: MultiplyTransactionPreview,
  options: {
    collateralSymbol: string
    borrowSymbol: string
    collateralAmount: number
    collateralPriceUsd: number
    catalogCollateralPriceUsd?: number
    marketLabel: string
    collateralApy: number
    borrowApy: number
    multiplier: number
    maxLtv: number
  },
): ActionPreviewUi {
  const priceScale =
    options.catalogCollateralPriceUsd && options.catalogCollateralPriceUsd > 0
      ? options.collateralPriceUsd / options.catalogCollateralPriceUsd
      : 1
  const scaleUsd = (value: number) => value * priceScale
  const healthAfter = hfNumber(preview.after.healthFactor)
  const liqPrice = preview.simulationSummary?.liquidationPrice
  const liquidationError = preview.validationErrors.find((entry) => entry.toLowerCase().includes("health factor"))
  const riskMessage =
    preview.warnings.find((entry) => entry.toLowerCase().includes("liquidation")) ??
    preview.warnings[0] ??
    "This leverage reduces your safety buffer."
  const hasExistingPosition = preview.before.collateralValueUsd > 0 || preview.before.debtValueUsd > 0
  const loopCount = Math.max(0, preview.simulationSummary?.loopCount ?? 0)
  const addedExposureUsd = scaleUsd(addedValue(preview.after.collateralValueUsd, preview.before.collateralValueUsd))
  const addedDebtUsd = scaleUsd(addedValue(preview.after.debtValueUsd, preview.before.debtValueUsd))
  const borrowCapacityUsd = Math.max(
    0,
    scaleUsd(preview.after.collateralValueUsd * options.maxLtv - preview.after.debtValueUsd),
  )
  const maxBorrowUsd = scaleUsd(preview.after.collateralValueUsd * options.maxLtv)
  const borrowCapacityRatio = maxBorrowUsd > 0 ? borrowCapacityUsd / maxBorrowUsd : 1
  const borrowCapacityTone = borrowCapacityRatio < 0.1 ? "danger" : borrowCapacityRatio < 0.25 ? "warning" : "positive"
  const metrics = [
    metricValue(
      "collateral-supplied",
      "Collateral",
      formatActionAmount(options.collateralAmount, options.collateralSymbol, 6),
    ),
    metricValue(
      "collateral-value",
      "Collateral value",
      formatActionUsd(options.collateralAmount * options.collateralPriceUsd),
    ),
    metricValue("target-leverage", "Target leverage", `${options.multiplier.toFixed(2)}x`),
    metricValue("looped-exposure", "Looped exposure", formatActionUsd(addedExposureUsd)),
    metricValue("borrowed-amount", `${options.borrowSymbol} borrowed`, formatActionUsd(addedDebtUsd)),
    // With an open loop the HF / LTV / APY below are for the combined position, so show that
    // position too; otherwise "Target leverage 1.10x" sat next to a ~2x projected result.
    ...(hasExistingPosition
      ? [
          metricBeforeAfter(
            "position-exposure",
            "Position exposure",
            formatActionUsd(scaleUsd(preview.before.collateralValueUsd)),
            formatActionUsd(scaleUsd(preview.after.collateralValueUsd)),
          ),
          metricBeforeAfter(
            "position-debt",
            "Position debt",
            formatActionUsd(scaleUsd(preview.before.debtValueUsd)),
            formatActionUsd(scaleUsd(preview.after.debtValueUsd)),
          ),
          metricBeforeAfter(
            "position-leverage",
            "Position leverage",
            `${preview.before.multiplier.toFixed(2)}x`,
            `${preview.after.multiplier.toFixed(2)}x`,
          ),
        ]
      : []),
    metricValue("borrow-capacity", "Borrow capacity remaining", formatActionUsd(borrowCapacityUsd), borrowCapacityTone),
    metricValue("ltv", hasExistingPosition ? "Projected LTV" : "LTV", formatActionRatioPercent(preview.after.ltv)),
    metricValue(
      "hf",
      hasExistingPosition ? "Projected health factor" : "Health factor",
      formatActionHealthFactor(healthAfter),
      hfTone(healthAfter),
    ),
    metricValue(
      "net-apy",
      hasExistingPosition ? "Projected net APY" : "Net APY",
      formatActionRatioPercent(preview.after.netApy),
    ),
    {
      id: "liq-price",
      label: "Liquidation price",
      value: liqPrice != null ? formatActionUsd(scaleUsd(liqPrice)) : "—",
    },
  ]

  return {
    quoteId: preview.intent.id,
    loopCount,
    executionSteps: [
      { id: "supply-initial", label: "Supply initial collateral" },
      ...Array.from({ length: loopCount }, (_, index) => [
        { id: `borrow-${index + 1}`, label: `Loop ${index + 1}: Borrow` },
        { id: `swap-${index + 1}`, label: `Loop ${index + 1}: Swap to collateral` },
        { id: `resupply-${index + 1}`, label: `Loop ${index + 1}: Resupply collateral` },
      ]).flat(),
    ],
    allowed: preview.allowed,
    amountTitle: "Collateral",
    amountLabel: formatActionAmount(options.collateralAmount, options.collateralSymbol, 6),
    amountValue: String(options.collateralAmount),
    assetLabel: options.collateralSymbol,
    assetSymbol: options.collateralSymbol,
    amountUsd: options.collateralAmount * options.collateralPriceUsd,
    amountUsdLabel: formatActionApproxUsd(options.collateralAmount * options.collateralPriceUsd),
    rateLabel: "",
    rateValue: "",
    marketLabel: "Market",
    // Omit Market row — pair is already in the page chrome; the Supply X · Borrow Y
    // card was redundant noise next to Avana Platform Fee.
    marketValue: "",
    balanceLabel: "Selected leverage",
    balanceValue: `${options.multiplier.toFixed(2)}x`,
    maxAmount: options.multiplier,
    metrics,
    networkFeeLabel: formatActionFeeSummary(options.collateralAmount * options.collateralPriceUsd),
    risk:
      preview.riskLabel === "danger" || (Number.isFinite(healthAfter) && healthAfter < NEAR_LIQUIDATION_HF)
        ? {
            level: "danger",
            title: "Risk of liquidation",
            message:
              liquidationError ??
              "This leverage leaves almost no safety buffer — the health factor is close to 1.0, where the position is liquidated.",
          }
        : preview.warnings.length > 0
          ? {
              level: "warning",
              title: "Review leverage carefully",
              message: riskMessage,
            }
          : null,
    blockedReason: preview.allowed ? null : (preview.validationErrors[0] ?? "Action unavailable"),
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapDeleveragePreviewToActionUi(
  preview: MultiplyTransactionPreview,
  options: {
    marketLabel: string
    targetMultiplier: number
    collateralSymbol: string
  },
): ActionPreviewUi {
  const healthAfter = hfNumber(preview.after.healthFactor)
  const liqPrice = preview.simulationSummary?.liquidationPrice

  return {
    quoteId: preview.intent.id,
    executionSteps: [
      { id: "unwind", label: "Withdraw looped collateral" },
      { id: "swap", label: "Swap collateral for debt asset" },
      { id: "repay", label: "Repay debt" },
      { id: "resupply", label: "Resupply remaining collateral" },
    ],
    allowed: preview.allowed,
    amountLabel: `${options.targetMultiplier.toFixed(2)}x ${options.collateralSymbol}`,
    amountValue: `${options.targetMultiplier.toFixed(2)}x`,
    assetLabel: options.collateralSymbol,
    assetSymbol: options.collateralSymbol,
    amountUsd: preview.after.collateralValueUsd,
    amountUsdLabel: formatActionApproxUsd(preview.after.collateralValueUsd),
    rateLabel: "",
    rateValue: "",
    marketLabel: "Market",
    marketValue: "",
    balanceLabel: "Target multiplier",
    balanceValue: `${options.targetMultiplier.toFixed(2)}x`,
    maxAmount: preview.before.multiplier,
    metrics: [
      metricBeforeAfter(
        "exposure",
        "Exposure",
        formatActionUsd(preview.before.collateralValueUsd),
        formatActionUsd(preview.after.collateralValueUsd),
      ),
      metricBeforeAfter(
        "debt",
        "Estimated debt",
        formatActionUsd(preview.before.debtValueUsd),
        formatActionUsd(preview.after.debtValueUsd),
      ),
      metricBeforeAfter(
        "ltv",
        "LTV",
        formatActionRatioPercent(preview.before.ltv),
        formatActionRatioPercent(preview.after.ltv),
      ),
      metricBeforeAfter(
        "hf",
        "Health factor",
        formatActionHealthFactor(hfNumber(preview.before.healthFactor)),
        formatActionHealthFactor(healthAfter),
        hfTone(healthAfter),
      ),
      metricBeforeAfter(
        "net-apy",
        "Net APY",
        formatActionRatioPercent(preview.before.netApy),
        formatActionRatioPercent(preview.after.netApy),
      ),
      {
        id: "liq-price",
        label: "Liquidation price",
        value: liqPrice != null ? formatActionUsd(liqPrice) : "—",
      },
    ],
    networkFeeLabel: formatActionFeeSummary(
      Math.max(0, preview.before.collateralValueUsd - preview.after.collateralValueUsd),
    ),
    risk:
      preview.riskLabel === "danger"
        ? {
            level: "danger",
            title: "This deleverage still leaves risk",
            message: preview.validationErrors[0] ?? "Health factor remains too low.",
          }
        : null,
    blockedReason: preview.allowed ? null : (preview.validationErrors[0] ?? "Action unavailable"),
    validationErrors: preview.validationErrors,
    warnings: preview.warnings,
  }
}

export function mapClosePreviewToActionUi(
  preview: MultiplyTransactionPreview,
  options: {
    marketLabel: string
    collateralSymbol: string
    /**
     * Collateral USD at the LIVE oracle price (`collateralAmount × livePrice`).
     *
     * The multiply session revalues positions against `market.collateralAsset.priceUsd`, which
     * is the catalog fixture captured at module load — the multiply/deleverage paths already
     * override it with the live price, but close never did. With AAVE at a $105 fixture and a
     * $120.18 oracle, a full close reported $95,380 unwound / $53,713 withdrawn against the
     * dashboard's $109,172 / $67,505: the same position, ~$13.8K apart. Prefer the live figure
     * and fall back to the preview when no live price is available.
     */
    liveCollateralValueUsd?: number
  },
): ActionPreviewUi {
  const collateralValueUsd =
    options.liveCollateralValueUsd != null &&
    Number.isFinite(options.liveCollateralValueUsd) &&
    options.liveCollateralValueUsd > 0
      ? options.liveCollateralValueUsd
      : preview.before.collateralValueUsd
  const equityUsd = Math.max(0, collateralValueUsd - preview.before.debtValueUsd)
  const priceImpactPct = Math.max(0, preview.simulationSummary?.priceImpactPct ?? 0)
  const swapLossUsd = preview.before.debtValueUsd * (priceImpactPct / 100)
  const minimumReceivedUsd = Math.max(0, equityUsd - swapLossUsd)
  const base = mapDeleveragePreviewToActionUi(preview, {
    marketLabel: options.marketLabel,
    targetMultiplier: 1,
    collateralSymbol: options.collateralSymbol,
  })
  return {
    ...base,
    amountLabel: `Full close ${options.collateralSymbol}`,
    amountValue: "Full close",
    amountUsd: minimumReceivedUsd,
    amountUsdLabel: formatActionUsd(minimumReceivedUsd, { exact: true }),
    rateLabel: "Final withdrawal",
    rateValue: formatActionUsd(minimumReceivedUsd, { exact: true }),
    balanceLabel: "Remaining dust",
    balanceValue: formatActionUsd(0, { exact: true }),
    metrics: [
      {
        id: "debt-repaid",
        label: "Debt repaid",
        value: formatActionUsd(preview.before.debtValueUsd, { exact: true }),
      },
      {
        id: "collateral-sold",
        label: "Collateral unwound",
        value: formatActionUsd(collateralValueUsd, { exact: true }),
      },
      {
        id: "swap-loss",
        label: "Estimated swap loss",
        value: formatActionUsd(swapLossUsd, { exact: true }),
        tone: swapLossUsd > 0 ? "warning" : "default",
      },
      {
        id: "minimum-received",
        label: "Minimum received",
        value: formatActionUsd(minimumReceivedUsd, { exact: true }),
        tone: "positive",
      },
      {
        id: "remaining-dust",
        label: "Remaining dust",
        value: formatActionUsd(0, { exact: true }),
      },
    ],
    risk: null,
  }
}
