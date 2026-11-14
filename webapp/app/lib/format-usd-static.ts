/**
 * Compact USD (K/M/B, 2dp) with a literal "$" and no currency conversion.
 *
 * For labels built on the Convex server or into server-shaped payloads, where the viewer's
 * active currency is unknown. Client UI should use the currency-aware `formatCompactUsd`
 * from `@/app/lib/format` instead. Pure: safe to import from `convex/`.
 */
export function formatCompactUsdStatic(value: number): string {
  const abs = Math.abs(value)
  if (abs >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`
  if (abs >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`
  if (abs >= 1_000) return `$${(value / 1_000).toFixed(2)}K`
  return `$${value.toFixed(2)}`
}
