/**
 * The Vercel Analytics / Speed Insights beacon (loaded at runtime in production)
 * POSTs to `/_vercel/insights/*`. When that request is blocked — ad blockers, an
 * offline tab, a strict corporate proxy — the SDK surfaces the rejection as an
 * uncaught "Analytics SDK: TypeError: Failed to fetch" console error. It is
 * entirely benign (telemetry is best-effort) but shows up as a page error.
 *
 * `isAnalyticsBeaconRejection` recognises exactly those rejections so the global
 * handler can swallow only them and let every other error propagate normally.
 */
export function isAnalyticsBeaconRejection(reason: unknown): boolean {
  const message =
    reason instanceof Error
      ? `${reason.name}: ${reason.message}`
      : typeof reason === "string"
        ? reason
        : String((reason as { message?: unknown } | null)?.message ?? reason ?? "")

  if (!/failed to fetch|networkerror|load failed/i.test(message)) return false

  return /analytics sdk|analyticssdkapierror|_vercel\/insights|@vercel\/analytics|speed[- ]?insights/i.test(message)
}
