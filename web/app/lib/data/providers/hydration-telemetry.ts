/**
 * Dev-only telemetry for silent per-field catalog fallbacks in market hydration.
 *
 * When `mergeConvex*Snapshots` receives a snapshot that omits an expected field
 * (name, symbol, maxLtvPct, reserveFactorPct, …), it silently keeps the catalog
 * value. That's the right degrade — the page still renders — but it turns the
 * snapshot's completeness into a stability question no one is looking at.
 *
 * This helper surfaces the incomplete snapshot as a one-time dev-console warn so
 * the seed / dailyStats writer gets fixed when a new field is added. Silent in
 * production and test — the tag `[live-hydration]` is grep-able for anyone reading
 * their local browser console.
 */

const warned = new Set<string>()

export function warnLiveFallback(product: "borrow" | "lend" | "multiply", slug: string, field: string): void {
  if (process.env.NODE_ENV !== "development") return
  const key = `${product}:${slug}:${field}`
  if (warned.has(key)) return
  warned.add(key)
  console.warn(
    `[live-hydration] ${product} snapshot "${slug}" is missing "${field}" — falling back to catalog. Fix the seed / dailyStats writer so the snapshot carries this field.`,
  )
}
