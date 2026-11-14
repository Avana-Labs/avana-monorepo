/**
 * Detail pages must fail closed in live mode when Convex has no reference snapshot for a
 * market — otherwise they silently render the mock catalog, showing numbers that don't
 * match the (empty) live list. `borrow` has enforced this since day one via
 * app/lib/borrow-detail/live-fallback.ts; this shared helper extends the same guard to
 * lend + multiply so no product silently degrades to mock in live mode.
 *
 * `hasData` is the SoT-per-product boolean: for borrow it's `snapshots.length > 0`
 * (the whole list query), for lend/multiply it's `snapshot != null` (the per-market
 * fetch). Mock mode never fails closed — the catalog is the intended source there.
 */
export function shouldFailClosedInLive(mode: "live" | "mock", hasData: boolean) {
  return mode === "live" && !hasData
}

/**
 * Per-field fail-close: prefer the Convex value in live mode; only fall back to the
 * mock value in mock mode. Use for detail-page fields where "silently mock" would
 * mask a real seeding gap on the visible page (e.g. risk assessment mismatch would
 * make the Risk card show one story while the QuickStat shows another). Returns
 * null in live mode when Convex has nothing — the caller decides whether to skip
 * the section or render an empty state.
 */
export function preferLiveOrNull<T>(mode: "live" | "mock", live: T | null | undefined, mock: T): T | null {
  if (live !== null && live !== undefined) return live
  return mode === "mock" ? mock : null
}
