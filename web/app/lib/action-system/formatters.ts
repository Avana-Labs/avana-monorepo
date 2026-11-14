import { getActiveCurrency, withCurrencySymbol } from "@/app/lib/currency/active-rate"
import { formatHealthFactor } from "@/app/lib/home-view-model"

export function formatActionInputAmount(value: number, maxDecimals = 6) {
  if (!Number.isFinite(value)) return "0"
  return String(Number(value.toFixed(maxDecimals)))
}

export function formatActionUsd(usdValue: number, options?: { compact?: boolean; exact?: boolean }) {
  if (!Number.isFinite(usdValue)) return "—"
  // Action amounts are computed in USD; convert into the active display currency.
  const { rate, zeroDecimal } = getActiveCurrency()
  const value = usdValue * rate
  // Compact thresholds/negatives are handled on the magnitude; the sign is
  // reattached (outside the symbol) by withCurrencySymbol.
  const abs = Math.abs(value)
  if (options?.compact) {
    if (abs >= 1_000_000_000) return withCurrencySymbol(value, `${(abs / 1_000_000_000).toFixed(1)}B`)
    if (abs >= 1_000_000) return withCurrencySymbol(value, `${(abs / 1_000_000).toFixed(1)}M`)
    if (abs >= 1_000) return withCurrencySymbol(value, `${(abs / 1_000).toFixed(1)}K`)
  }
  const fractionDigits = zeroDecimal ? 0 : options?.exact || abs < 100 ? 2 : 0
  return withCurrencySymbol(
    value,
    abs.toLocaleString("en-US", { minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits }),
  )
}

export function formatActionApproxUsd(value: number) {
  return formatActionUsd(value)
}

export function formatActionPercent(value: number, digits = 2) {
  if (!Number.isFinite(value)) return "—"
  // Fixed decimals, matching formatActionRatioPercent, so a given LTV/APY reads identically on
  // every surface (80 -> "80.00%", not "80%").
  return `${value.toFixed(digits)}%`
}

export function formatActionRatioPercent(value: number, digits = 2) {
  if (!Number.isFinite(value)) return "—"
  return `${(value * 100).toFixed(digits)}%`
}

export function formatActionHealthFactor(value: number | null) {
  return formatHealthFactor(value)
}

export function formatActionBeforeAfter(before: string, after: string) {
  return `${before} → ${after}`
}

export function formatActionUsdBeforeAfter(beforeUsd: number, afterUsd: number) {
  return formatActionBeforeAfter(formatActionUsd(beforeUsd), formatActionUsd(afterUsd))
}

export function formatActionPercentBeforeAfter(beforePct: number, afterPct: number, digits = 2) {
  return formatActionBeforeAfter(formatActionPercent(beforePct, digits), formatActionPercent(afterPct, digits))
}

export function formatActionNetworkFee(value: number) {
  if (!Number.isFinite(value) || value <= 0) return "~ $0.00"
  return `~ ${formatActionUsd(value)}`
}

/**
 * The single canonical sandbox network-fee estimate (USD). Preview and receipt must both read
 * this one number, or the estimate and the recorded fee drift apart.
 */
export const SANDBOX_NETWORK_FEE_USD = 0.03

/** Avana interface fee: 15 bps of the transaction's USD value (see the fee tooltip). */
export const AVANA_PLATFORM_FEE_BPS = 15

export function avanaPlatformFeeUsd(amountUsd: number) {
  if (!Number.isFinite(amountUsd) || amountUsd <= 0) return 0
  return (amountUsd * AVANA_PLATFORM_FEE_BPS) / 10_000
}

/**
 * The "Avana Platform Fee" row: 15 bps of the action's USD amount. It read a flat "~$0.03" for
 * $100 and $5,000 alike. The extra params are kept for call-site compatibility.
 */
export function formatActionFeeSummary(amountUsd: number, _networkFeeUsd?: number, _bps?: number) {
  return formatActionNetworkFee(avanaPlatformFeeUsd(amountUsd))
}

export function formatActionAmount(assetAmount: number, symbol: string, digits = 6) {
  if (!Number.isFinite(assetAmount)) return `0 ${symbol}`
  // Trailing zeros drop in both branches ("12,500", not "12,500.00") while fractional amounts
  // keep their significant digits. Thousands are grouped: "13099.82" and "78102749.86" were
  // hard to read next to the grouped USD figures.
  const rounded = assetAmount.toLocaleString("en-US", {
    maximumFractionDigits: assetAmount >= 100 ? 2 : Math.min(digits, 6),
    minimumFractionDigits: 0,
  })
  return `${rounded} ${symbol}`
}
