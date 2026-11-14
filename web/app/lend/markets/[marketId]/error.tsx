"use client"

import { useEffect } from "react"
import { RouteErrorFallback } from "@/app/components/route-error-fallback"

/** Route-level error boundary for the market detail page — renders the branded
 *  recovery UI instead of a blank screen when the detail fails to render. */
export default function MarketDetailError({ error, reset }: { error: Error; reset: () => void }) {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") console.error(error)
  }, [error])

  return <RouteErrorFallback onRetry={reset} error={error} />
}
