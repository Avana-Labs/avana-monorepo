import type { CurrencyCode, LanguageCode } from "@/app/components/display-preferences"
import { currencySymbolFor, exchangeRateFor, ZERO_DECIMAL_CURRENCIES } from "@/app/lib/currency/rates"
import { LANGUAGE_HTML_LANG } from "@/app/lib/i18n/language-html-lang"

/**
 * Module-level "active currency" that the shared USD formatters read so a single
 * switch in the header re-denominates amounts across the app without threading a
 * currency arg through hundreds of call sites.
 *
 * SSR safety: this is NEVER mutated on the server (only the client provider calls
 * setActiveCurrency, in an effect/handler), so server renders always emit USD and
 * the first client render matches before converting post-hydration.
 */
type ActiveCurrency = { currency: CurrencyCode; rate: number; symbol: string; zeroDecimal: boolean }

let active: ActiveCurrency = { currency: "USD", rate: 1, symbol: "$", zeroDecimal: false }

export function setActiveCurrency(currency: CurrencyCode): void {
  active = {
    currency,
    rate: exchangeRateFor(currency),
    symbol: currencySymbolFor(currency),
    zeroDecimal: ZERO_DECIMAL_CURRENCIES.has(currency),
  }
}

export function getActiveCurrency(): ActiveCurrency {
  return active
}

/**
 * Module-level "active locale" (BCP-47) that the shared number formatters read so digit grouping
 * and decimal separators follow the viewer's selected language — a German viewer sees 1.234,56,
 * an Indian viewer sees lakh grouping — WITHOUT changing the app's deliberate custom currency
 * symbols. Defaults to "en-US" and is only mutated client-side (same SSR-safety contract as the
 * active currency), so server renders and the first client render group in en-US, matching before
 * the post-hydration language effect applies the real locale.
 */
let activeLocale = "en-US"

export function setActiveLocale(language: LanguageCode): void {
  activeLocale = LANGUAGE_HTML_LANG[language] ?? "en-US"
}

export function getActiveLocale(): string {
  return activeLocale
}

/** Convert a USD amount to the active currency (identity when USD). */
export function toActive(usdValue: number): number {
  return usdValue * active.rate
}

/**
 * Compose an already-formatted numeric body with the active currency symbol,
 * placing the minus sign OUTSIDE the symbol ("-$500", never "$-500") and never
 * emitting a negative sign for a value that rounds to zero ("$0.00", never
 * "$-0.00"). Shared by every USD formatter so negative handling is uniform.
 */
export function withCurrencySymbol(value: number, formattedAbs: string): string {
  const negative = value < 0 && Number(formattedAbs) !== 0
  return `${negative ? "-" : ""}${active.symbol}${formattedAbs}`
}
