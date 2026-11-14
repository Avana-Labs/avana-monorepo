"use client"

import { useEffect } from "react"
import { RouteErrorFallback } from "@/app/components/route-error-fallback"

/** Route-level error boundary for /dashboard — renders the branded recovery UI. */
export default function DashboardError({ error, reset }: { error: Error; reset: () => void }) {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") console.error(error)
  }, [error])

  return <RouteErrorFallback onRetry={reset} error={error} homeHref="/dashboard" homeLabel="Back to dashboard" />
}
