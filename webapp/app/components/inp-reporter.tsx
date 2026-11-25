"use client"

import { useEffect } from "react"

/**
 * Captures INP *attribution* — the one thing the aggregate "2568ms" number can't tell you:
 * which route, which DOM element, and which phase (input delay / processing / presentation)
 * the slow interaction actually happened on. web-vitals is lazy-imported after mount so it
 * never touches the critical path.
 *
 * - Dev: logs each new worst interaction to the console (interact with the app and read it).
 * - Prod (only when `enableBeacon`): beacons to /api/vitals. Never beacon when reporting is
 *   disabled — the API 204 still costs a Vercel invocation if the request reaches it.
 */
export function InpReporter({ enableBeacon = false }: { enableBeacon?: boolean }) {
  useEffect(() => {
    let cancelled = false
    const isDev = process.env.NODE_ENV !== "production"

    import("web-vitals/attribution")
      .then(({ onINP }) => {
        if (cancelled) return
        onINP(
          (metric) => {
            const a = metric.attribution
            const payload = {
              metric: "INP",
              value: Math.round(metric.value),
              rating: metric.rating,
              route: typeof location !== "undefined" ? location.pathname : "",
              interactionType: a?.interactionType,
              target: a?.interactionTarget,
              inputDelay: Math.round(a?.inputDelay ?? 0),
              processingDuration: Math.round(a?.processingDuration ?? 0),
              presentationDelay: Math.round(a?.presentationDelay ?? 0),
              loadState: a?.loadState,
            }

            if (isDev) {
              console.warn(
                `[INP] ${payload.value}ms (${payload.rating}) on ${payload.route}\n` +
                  `      target: ${payload.target}\n` +
                  `      phases: input ${payload.inputDelay}ms · processing ${payload.processingDuration}ms · present ${payload.presentationDelay}ms`,
                payload,
              )
            }

            if (!enableBeacon) return
            try {
              // sendBeacon survives page unload; same-origin so it passes connect-src 'self'.
              navigator.sendBeacon?.("/api/vitals", JSON.stringify(payload))
            } catch {
              // Telemetry is best-effort — never throw from the reporter.
            }
          },
          // Report every new worst interaction in dev (live feedback); in prod report once at
          // the end (the standard, low-volume behaviour).
          { reportAllChanges: isDev },
        )
      })
      .catch(() => {
        // web-vitals is optional; ignore load failures.
      })

    return () => {
      cancelled = true
    }
  }, [enableBeacon])

  return null
}
