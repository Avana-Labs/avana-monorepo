/**
 * Explicit live-or-fallback seam for whole-object Convex reads.
 *
 * Detail loaders used to write `(await getXFromConvex(id)) ?? getXMock(id)`. That
 * silently renders MOCK data whenever the live read returns null — invisible in
 * production, so a Convex outage or an un-seeded market degrades to fixtures with
 * nothing surfaced. `warnLiveFallback` (hydration-telemetry.ts) covers per-FIELD
 * fallback inside a merge; this covers the whole-object live-or-mock decision.
 *
 * `preferLive` preserves the exact runtime behavior of `live ?? fallback` (so it is
 * a safe drop-in) but emits a one-time, dev-only, grep-able `[prefer-live]` warning
 * whenever the fallback is taken. `preferLiveOrNull` is for call sites that would
 * rather surface absence (null → notFound / empty state) than render a mock.
 *
 * Silent in production and test.
 */

const warned = new Set<string>()

function warnFallback(context: string, action: string): void {
  if (process.env.NODE_ENV !== "development") return
  if (warned.has(context)) return
  warned.add(context)
  console.warn(`[prefer-live] ${context}: live data unavailable — ${action}. Check the Convex read / seed for this id.`)
}

/**
 * Return `live` when present; otherwise return `fallback` and warn once in dev.
 * Runtime-identical to `live ?? fallback` — a drop-in that makes the seam loud.
 */
export function preferLive<T>(live: T | null | undefined, fallback: T, context: string): T {
  if (live != null) return live
  warnFallback(context, "rendering mock fallback")
  return fallback
}

/**
 * Return `live` when present; otherwise return `null` and warn once in dev. Use
 * where surfacing absence is better than a mock (the caller renders notFound/empty).
 */
export function preferLiveOrNull<T>(live: T | null | undefined, context: string): T | null {
  if (live != null) return live
  warnFallback(context, "surfacing null")
  return null
}
