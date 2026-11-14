import { formatCompactUsd as formatCompactUsdCanonical, formatUsdExact } from "@/app/lib/borrow-sim"

// Umbrella money display MUST route through these shared currency-aware formatters:
// a hardcoded "$" ignores the header currency switcher and mixes €/$ on one screen.

/** Currency-aware exact USD (honours the active currency + its rate/symbol). */
export function formatUsd(value: number) {
  return formatUsdExact(value)
}

/** Currency-aware compact USD (K/M/B), shared with borrow/lend/multiply. */
export function formatCompactUsd(value: number) {
  return formatCompactUsdCanonical(value)
}

/** Percent body only (callers append "%"). Variable precision, currency-agnostic. */
export function formatPct(value: number) {
  return value.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 2 })
}

export function formatUnits(value: number) {
  const fraction = Number.isInteger(value) ? 0 : 3
  return value.toLocaleString("en-US", {
    minimumFractionDigits: fraction,
    maximumFractionDigits: fraction,
  })
}
