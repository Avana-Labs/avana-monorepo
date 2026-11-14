"use client"

import { Fragment, type ReactNode } from "react"
import { useLocaleDisplayPreferences } from "@/app/components/display-preferences"
import { exchangeRateFor } from "@/app/lib/currency/rates"

/**
 * Shared market formatters read the active FX rate from a module. Recreate only
 * the rendered route when currency changes so every table/detail recalculates,
 * while the wallet and product sessions above this boundary remain intact.
 */
export function CurrencyDisplayBoundary({ children }: { children: ReactNode }) {
  const { currency } = useLocaleDisplayPreferences()

  // Context updates still re-render this boundary when ratesVersion changes.
  // Only an effective conversion change needs to rebuild module-based tables:
  // repeated rates, other currencies, and all USD updates must preserve the page.
  return <Fragment key={`${currency}:${exchangeRateFor(currency)}`}>{children}</Fragment>
}
