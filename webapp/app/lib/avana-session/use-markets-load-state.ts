"use client"

import { useEffect, useState } from "react"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { captureException } from "@/app/lib/monitoring/sentry-client"

/** How long the home tabs wait for markets before showing the failed-load state. */
export const MARKETS_LOAD_TIMEOUT_MS = 15_000

/** One Sentry event per page session for a markets outage, however many times the user retries. */
let outageReported = false

export type MarketsLoadState = "loading" | "ready" | "failed"

/**
 * Whether the session's markets arrived. Without a Convex URL they never will (a local
 * misconfiguration, reported nowhere), so the state is "failed" at once; with one, markets still
 * missing after {@link MARKETS_LOAD_TIMEOUT_MS} is an outage, sent to Sentry once. `attempt`
 * restarts the wait (Try again).
 */
export function useMarketsLoadState(ready: boolean, attempt: number, convexConfigured = hasConvexClient): MarketsLoadState {
  const [timedOutAttempt, setTimedOutAttempt] = useState<number | null>(null)

  useEffect(() => {
    if (ready || !convexConfigured) return
    const timer = setTimeout(() => {
      setTimedOutAttempt(attempt)
      if (outageReported) return
      outageReported = true
      void captureException(new Error(`Markets did not load within ${MARKETS_LOAD_TIMEOUT_MS / 1000} s`))
    }, MARKETS_LOAD_TIMEOUT_MS)
    return () => clearTimeout(timer)
  }, [ready, attempt, convexConfigured])

  if (ready) return "ready"
  if (!convexConfigured) return "failed"
  return timedOutAttempt === attempt ? "failed" : "loading"
}

/** Test seam: forget that the outage was reported. */
export function resetMarketsOutageReport() {
  outageReported = false
}
