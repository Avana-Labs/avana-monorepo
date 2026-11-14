// A multiply position is capped by two things: what the user's wallet can afford
// (the collateral they actually hold) and what the market can absorb (available
// liquidity). Max should fill the wallet balance — not the market's multi-million
// liquidity — while still rejecting absurd inputs before the simulation engine.

import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"
import { formatActionAmount, formatActionApproxUsd, formatActionFeeSummary } from "@/app/lib/action-system/formatters"

/**
 * Maximum collateral amount (in collateral units), capped by the smaller of the
 * wallet balance and the market's available liquidity. `walletBalanceUsd` defaults
 * to unbounded so callers that only care about the liquidity ceiling are unchanged.
 * Returns null if the inputs can't yield a meaningful cap.
 */
export function maxMultiplyCollateralAmount(
  availableLiquidityUsd: number,
  collateralPriceUsd: number,
  walletBalanceUsd: number = Number.POSITIVE_INFINITY,
): number | null {
  if (!Number.isFinite(availableLiquidityUsd) || availableLiquidityUsd <= 0) return null
  if (!Number.isFinite(collateralPriceUsd) || collateralPriceUsd <= 0) return null
  if (Number.isFinite(walletBalanceUsd) && walletBalanceUsd <= 0) return 0
  const capUsd = Math.min(availableLiquidityUsd, Math.max(0, walletBalanceUsd))
  if (capUsd <= 0) return Number.isFinite(walletBalanceUsd) ? 0 : null
  return capUsd / collateralPriceUsd
}

/**
 * Resolve the collateral price the action panel should VALUE the position at. Prefer the
 * live oracle price, but only when it is a usable positive number — otherwise fall back to
 * the catalog price. A plain `livePrice ?? catalogPrice` let a 0/NaN oracle reading through,
 * which zeroed every client-side USD figure (the collateral sublabel and value) while the
 * engine — which independently guards for a positive override — still valued the exposure at
 * the catalog price. Sharing this guard binds the displayed valuation to the exposure. (E5)
 */
export function resolveMultiplyCollateralPriceUsd(livePriceUsd: number | undefined, catalogPriceUsd: number): number {
  if (livePriceUsd != null && Number.isFinite(livePriceUsd) && livePriceUsd > 0) return livePriceUsd
  return catalogPriceUsd
}

/** True when the collateral amount exceeds what the market's liquidity can support. */
export function exceedsMultiplyCollateralCap(collateralAmount: number, maxCollateralAmount: number | null): boolean {
  if (maxCollateralAmount == null) return false
  if (!Number.isFinite(collateralAmount)) return true
  return collateralAmount > maxCollateralAmount
}

/** Human-readable reason for an over-cap collateral amount. */
export function multiplyOverCapReason(collateralSymbol: string, maxCollateralAmount: number): string {
  return `Amount exceeds your available balance. Max ${formatActionAmount(maxCollateralAmount, collateralSymbol, 6)}.`
}

/**
 * A blocked preview shown when the entered collateral exceeds the market cap, so the
 * flow rejects the amount with a clear message instead of running a doomed simulation.
 */
export function buildMultiplyOverCapPreviewUi(options: {
  collateralSymbol: string
  borrowSymbol: string
  collateralAmount: number
  collateralPriceUsd: number
  marketLabel: string
  multiplier: number
  maxCollateralAmount: number
}): ActionPreviewUi {
  const reason = multiplyOverCapReason(options.collateralSymbol, options.maxCollateralAmount)
  return {
    allowed: false,
    amountTitle: "Collateral",
    amountLabel: formatActionAmount(options.collateralAmount, options.collateralSymbol, 6),
    amountValue: String(options.collateralAmount),
    assetLabel: options.collateralSymbol,
    assetSymbol: options.collateralSymbol,
    amountUsdLabel: formatActionApproxUsd(options.collateralAmount * options.collateralPriceUsd),
    rateLabel: "",
    rateValue: "",
    marketLabel: "Market",
    marketValue: "",
    balanceLabel: "Balance",
    balanceValue: formatActionAmount(options.maxCollateralAmount, options.collateralSymbol, 6),
    maxAmount: options.maxCollateralAmount,
    metrics: [],
    networkFeeLabel: formatActionFeeSummary(options.collateralAmount * options.collateralPriceUsd),
    risk: null,
    blockedReason: reason,
    validationErrors: [reason],
    warnings: [],
  }
}
