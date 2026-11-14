/**
 * Server fetchers degrade to the catalog (null / []) when a Convex read fails, which is the
 * right render behaviour but used to leave no trace: a deadline, a renamed query or an auth
 * error looked exactly like "no data". Log the fetcher name and cause so the fallback is
 * visible in the server logs. Keep the log to one line with no payload.
 */
export type ServerFetchContext = {
  product?: "borrow" | "lend" | "multiply"
  route?: string
  slug?: string
  query?: string
}

function contextLabels(context: ServerFetchContext): string {
  return Object.entries(context)
    .filter(([, value]) => value)
    .map(([key, value]) => `${key}=${value}`)
    .join(" ")
}

export function reportServerFetchFailure(fetcher: string, error: unknown, context: ServerFetchContext = {}): void {
  const reason = error instanceof Error ? `${error.name}: ${error.message}` : String(error)
  const labels = contextLabels(context)
  console.warn(`[server-fetch] ${fetcher}${labels ? ` ${labels}` : ""} fell back: ${reason.slice(0, 300)}`)
}

/** Opt-in success trace for diagnosing duplicate detail reads without noisy production logs. */
export function reportServerFetchSuccess(fetcher: string, context: ServerFetchContext, durationMs: number): void {
  if (process.env.NODE_ENV !== "development") return
  const labels = contextLabels(context)
  // eslint-disable-next-line no-console -- opt-in local request trace
  console.debug(`[server-fetch] ${fetcher}${labels ? ` ${labels}` : ""} ok durationMs=${durationMs}`)
}
