import type { CurrencyCode } from "@/app/components/display-preferences"
import { getActiveLocale } from "@/app/lib/currency/active-rate"
import { currencySymbolFor, exchangeRateFor, ZERO_DECIMAL_CURRENCIES } from "@/app/lib/currency/rates"

/**
 * Format the NUMBER part with the viewer's active locale (grouping + decimal separators) via
 * Intl.NumberFormat, instead of a hardcoded "en-US". The custom currency symbol is applied
 * separately by the callers, so this fixes locale-correct grouping (incl. Indian lakh grouping)
 * without changing the app's deliberate symbols. Defaults to en-US, so SSR/tests are unchanged.
 */
function formatNumber(value: number, options: Intl.NumberFormatOptions): string {
  return new Intl.NumberFormat(getActiveLocale(), options).format(value)
}

export type CurrencyContext = {
  currency: CurrencyCode
  /** Units of `currency` per 1 USD. */
  rate: number
  symbol: string
}

export function currencyContext(currency: CurrencyCode, rateOverride?: number): CurrencyContext {
  return {
    currency,
    rate: rateOverride && rateOverride > 0 ? rateOverride : exchangeRateFor(currency),
    symbol: currencySymbolFor(currency),
  }
}

/** Convert a USD value into the active currency. */
export function convertFromUsd(usd: number, ctx: CurrencyContext): number {
  return usd * ctx.rate
}

/** Compact currency formatting (e.g. $1.6M / ¥11.5M / €1.5M) from a USD value. */
export function formatCompactCurrency(usd: number, ctx: CurrencyContext): string {
  const value = convertFromUsd(usd, ctx)
  const abs = Math.abs(value)
  const sign = value < 0 ? "-" : ""
  const mantissa = (n: number) => formatNumber(n, { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  if (abs >= 1_000_000_000) return `${sign}${ctx.symbol}${mantissa(abs / 1_000_000_000)}B`
  if (abs >= 1_000_000) return `${sign}${ctx.symbol}${mantissa(abs / 1_000_000)}M`
  if (abs >= 1_000) return `${sign}${ctx.symbol}${mantissa(abs / 1_000)}K`
  // Sub-$1000 shows the plain amount; keep cents for decimal currencies (JPY/KRW/etc. drop
  // them). The old ternary returned 0 in BOTH branches, rounding e.g. $500.50 to "$501".
  const decimals = ZERO_DECIMAL_CURRENCIES.has(ctx.currency) ? 0 : 2
  return `${sign}${ctx.symbol}${formatNumber(abs, { maximumFractionDigits: decimals })}`
}

/**
 * Token-denominated quantity with its symbol, e.g. "29.46M frxUSD". Used for the
 * primary line of a two-number table cell (the matching USD value sits below it),
 * mirroring the Lend table's TOTAL DEPOSITS / AVAILABLE columns.
 */
export function formatTokenQuantity(value: number, symbol: string): string {
  if (!Number.isFinite(value)) return `— ${symbol}`
  if (value > 0 && value < 0.01) return `<0.01 ${symbol}`
  const twoDp = (n: number) => formatNumber(n, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  if (value >= 1_000_000) return `${twoDp(value / 1_000_000)}M ${symbol}`
  if (value >= 1_000) return `${twoDp(value / 1_000)}K ${symbol}`
  return `${formatNumber(value, { maximumFractionDigits: 2 })} ${symbol}`
}

/**
 * Token quantity for the Activity feed. The executed token amount is not persisted — the durable
 * transaction records only USD — so the amount shown here is reconstructed as `amountUsd / price`.
 * Its low-order digits are oracle-drift noise, not real precision (a 100 USDC supply reconstructs
 * to 100.0035). Round to a magnitude-appropriate scale so a round-number action reads cleanly
 * ("100 USDC", "1 GHO") while a genuinely fractional balance stays legible ("0.4932 cbBTC").
 */
export function formatActivityTokenAmount(amount: number, symbol: string): string {
  if (!Number.isFinite(amount)) return `0 ${symbol}`
  const abs = Math.abs(amount)
  // The executed token amount is reconstructed from the transaction's USD value, so its low-order
  // digits are oracle-drift noise (~1% relative), not real precision. Below 1,000 units round to 3
  // significant figures — enough to hide that noise, so a round-number action reads cleanly
  // ("100.0135 USDC" → "100", "50.01 USDC" → "50", "1.0004 GHO" → "1") while a fractional balance
  // stays legible ("0.492 cbBTC"). At/above 1,000 units keep the integer so a large deposit still
  // reads naturally ("12,513 GHO") instead of collapsing to 3 figures.
  const rounded =
    abs >= 1_000
      ? formatNumber(amount, { maximumFractionDigits: 0 })
      : formatNumber(amount, { maximumSignificantDigits: 3 })
  return `${rounded} ${symbol}`
}

/** Exact currency formatting from a USD value, with currency-appropriate decimals. */
export function formatExactCurrency(usd: number, ctx: CurrencyContext): string {
  const value = convertFromUsd(usd, ctx)
  const decimals = ZERO_DECIMAL_CURRENCIES.has(ctx.currency) ? 0 : 2
  return `${value < 0 ? "-" : ""}${ctx.symbol}${formatNumber(Math.abs(value), {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`
}

/**
 * Per-unit price with adaptive precision, so `amount × displayed price` reconciles with the
 * displayed value instead of rounding a near-$1 token to a flat "$1.00" (13,349.72 USDC @ "$1.00"
 * would read "$13,343.63"). Large prices keep two decimals (unchanged for blue-chips), mid prices
 * show up to four, and sub-$1 prices up to six — capped so nothing runs long, and never fewer than
 * the currency's usual decimals.
 */
export function formatPriceCurrency(usd: number, ctx: CurrencyContext): string {
  const value = convertFromUsd(usd, ctx)
  const abs = Math.abs(value)
  const minDecimals = ZERO_DECIMAL_CURRENCIES.has(ctx.currency) ? 0 : 2
  const maxDecimals = ZERO_DECIMAL_CURRENCIES.has(ctx.currency) ? 0 : abs >= 100 ? 2 : abs >= 1 ? 4 : 6
  return `${value < 0 ? "-" : ""}${ctx.symbol}${formatNumber(abs, {
    minimumFractionDigits: Math.min(minDecimals, maxDecimals),
    maximumFractionDigits: maxDecimals,
  })}`
}

// A compact USD amount as produced by formatCompactUsd/formatCompactCurrency:
// optional sign, "$", digits (with optional thousands separators / decimals),
// and an optional B/M/K suffix. Anything else (percentages, plain text, prices
// with cents) is left untouched.
const COMPACT_USD_RE = /^(<?)(-?)\$([\d,]+(?:\.\d+)?)([BMK]?)$/

/**
 * Re-denominate an already-formatted compact USD string (e.g. "$312.4M") into the
 * active currency. Detail surfaces bake their quick-stat values as USD strings at
 * build time; this lets the shared switcher convert them on the client without
 * threading raw numbers through every producer. Non-USD or non-money strings pass
 * through unchanged.
 */
export function redenominateCompactUsd(value: string, ctx: CurrencyContext): string {
  if (ctx.currency === "USD") return value
  const match = COMPACT_USD_RE.exec(value.trim())
  if (!match) return value
  const [, lessThan, sign, digits, suffix] = match
  if (lessThan) {
    return `<${ctx.symbol}${ZERO_DECIMAL_CURRENCIES.has(ctx.currency) ? "1" : "0.01"}`
  }
  const multiplier = suffix === "B" ? 1_000_000_000 : suffix === "M" ? 1_000_000 : suffix === "K" ? 1_000 : 1
  const usd = Number(digits.replace(/,/g, "")) * multiplier
  if (!Number.isFinite(usd)) return value
  const signed = sign === "-" ? -usd : usd
  // Suffixed magnitudes stay compact; a plain sub-thousand amount (e.g. a token
  // price "$883.74") keeps its decimals so it matches the live tooltip/axis.
  return suffix ? formatCompactCurrency(signed, ctx) : formatExactCurrency(signed, ctx)
}
