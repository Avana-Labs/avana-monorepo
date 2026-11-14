import type { CurrencyCode } from "@/app/components/display-preferences"

/**
 * Window event fired after live FX rates are applied; DisplayPreferencesProvider listens and
 * bumps its rate version. Lives in this module because no test mocks it.
 */
export const FX_RATES_UPDATED_EVENT = "avana:fx-rates-updated"

/**
 * Units of currency per 1 USD. A static baseline so the switcher works on the server and
 * offline; `applyLiveRates` overrides per-currency at runtime and unlisted rates fall back here.
 */
export const USD_PER_UNIT_BASELINE: Record<CurrencyCode, number> = {
  USD: 1,
  ARS: 1015,
  AUD: 1.52,
  BRL: 5.6,
  CAD: 1.37,
  CNY: 7.18,
  COP: 4050,
  EUR: 0.92,
  GBP: 0.79,
  HKD: 7.8,
  IDR: 16100,
  INR: 83.4,
  JPY: 151,
  KRW: 1355,
}

/** Display symbol/prefix for each currency. */
const CURRENCY_SYMBOLS: Record<CurrencyCode, string> = {
  USD: "$",
  ARS: "AR$",
  AUD: "A$",
  BRL: "R$",
  CAD: "C$",
  CNY: "CN¥",
  COP: "CO$",
  EUR: "€",
  GBP: "£",
  HKD: "HK$",
  IDR: "Rp",
  INR: "₹",
  JPY: "¥",
  KRW: "₩",
}

/** Currencies conventionally shown with no decimal places. */
export const ZERO_DECIMAL_CURRENCIES: ReadonlySet<CurrencyCode> = new Set<CurrencyCode>([
  "JPY",
  "KRW",
  "IDR",
  "COP",
  "ARS",
])

/**
 * Live FX overlay, units per 1 USD. Seeded on the server from the same source as
 * `/api/fx-rates` so SSR and the first client render share one map.
 */
const liveRates: Partial<Record<CurrencyCode, number>> = {}

/** Overlay live rates on top of the baseline. Ignores non-positive/NaN values. */
export function applyLiveRates(rates: Partial<Record<CurrencyCode, number>>): void {
  for (const code of Object.keys(rates) as CurrencyCode[]) {
    // USD is the accounting base unit, not a market quote: pin it to 1 so a malformed
    // upstream row can never revalue $1.
    if (code === "USD") {
      liveRates.USD = 1
      continue
    }
    const rate = rates[code]
    if (typeof rate === "number" && Number.isFinite(rate) && rate > 0) {
      liveRates[code] = rate
    }
  }
}

export function exchangeRateFor(currency: CurrencyCode): number {
  if (currency === "USD") return 1
  const live = liveRates[currency]
  if (typeof live === "number" && Number.isFinite(live) && live > 0) {
    return live
  }
  const rate = USD_PER_UNIT_BASELINE[currency]
  return Number.isFinite(rate) && rate > 0 ? rate : 1
}

export function currencySymbolFor(currency: CurrencyCode): string {
  return CURRENCY_SYMBOLS[currency] ?? "$"
}
