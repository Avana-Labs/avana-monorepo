"use client"

import { useEffect } from "react"
import { RouteErrorFallback } from "@/app/components/route-error-fallback"

/**
 * Root route-level error boundary. Catches render errors in any segment that
 * doesn't provide its own error.tsx (borrow, lend, dashboard, rewards,
 * portfolio, etc.) so they surface a branded recovery UI instead of the
 * framework default error page.
 */
export default function RootError({ error, reset }: { error: Error; reset: () => void }) {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") console.error(error)
  }, [error])

  return <RouteErrorFallback onRetry={reset} error={error} />
}
