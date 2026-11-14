"use client"

import { useMemo } from "react"
import { useOptionalLocaleDisplayPreferences } from "@/app/components/display-preferences"
import {
  convertFromUsd,
  currencyContext,
  formatCompactCurrency,
  formatExactCurrency,
  formatPriceCurrency,
  type CurrencyContext,
} from "@/app/lib/currency/format"

type CurrencyFormatter = {
  ctx: CurrencyContext
  /** USD → active currency, compact (e.g. ¥11.5M). */
  compact: (usd: number) => string
  /** USD → active currency, exact with decimals. */
  exact: (usd: number) => string
  /** USD → active currency, per-unit price with adaptive precision (amount × price reconciles). */
  price: (usd: number) => string
  /** Raw converted number, if a caller needs to format itself. */
  convert: (usd: number) => number
  isUsd: boolean
}

/**
 * Currency formatter bound to the header switcher. All computation stays in USD
 * (oracle prices are USD); conversion happens only at the display layer.
 */
export function useCurrency(): CurrencyFormatter {
  const preferences = useOptionalLocaleDisplayPreferences()
  const currency = preferences?.currency ?? "USD"
  // Recompute when live FX rates are (re)applied, not just on a currency switch.
  const ratesVersion = preferences?.ratesVersion ?? 0
  return useMemo(() => {
    const ctx = currencyContext(currency)
    return {
      ctx,
      compact: (usd: number) => formatCompactCurrency(usd, ctx),
      exact: (usd: number) => formatExactCurrency(usd, ctx),
      price: (usd: number) => formatPriceCurrency(usd, ctx),
      convert: (usd: number) => convertFromUsd(usd, ctx),
      isUsd: currency === "USD",
    }
  }, [currency, ratesVersion])
}
