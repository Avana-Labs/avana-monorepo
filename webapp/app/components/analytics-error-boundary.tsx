"use client"

import { useEffect } from "react"
import { isAnalyticsBeaconRejection } from "@/app/lib/analytics/suppress-beacon-errors"

/**
 * Swallows the benign "Analytics SDK: Failed to fetch" unhandled rejection the
 * Vercel beacon throws when its POST is blocked (ad blockers / offline), so it
 * doesn't surface as a page error. Only analytics-beacon rejections are handled;
 * everything else propagates unchanged.
 */
export function AnalyticsErrorSuppressor() {
  useEffect(() => {
    const handleRejection = (event: PromiseRejectionEvent) => {
      if (isAnalyticsBeaconRejection(event.reason)) {
        event.preventDefault()
      }
    }

    window.addEventListener("unhandledrejection", handleRejection)
    return () => window.removeEventListener("unhandledrejection", handleRejection)
  }, [])

  return null
}
