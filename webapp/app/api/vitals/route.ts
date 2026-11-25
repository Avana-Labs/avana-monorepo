/**
 * Collector for the INP attribution beacons sent by <InpReporter />. Deliberately trivial:
 * it just structured-logs the payload (visible in Vercel function logs / the local terminal)
 * so the real slow interaction can be identified without a third-party analytics service.
 * sendBeacon posts a text/plain body, so parse the raw text rather than request.json().
 */
export async function POST(request: Request) {
  if (process.env.ENABLE_WEB_VITALS_LOGS !== "1") {
    return new Response(null, { status: 204 })
  }

  const origin = request.headers.get("origin")
  const host = request.headers.get("host")
  if (origin && host) {
    try {
      if (new URL(origin).host !== host) {
        return new Response(null, { status: 403 })
      }
    } catch {
      return new Response(null, { status: 403 })
    }
  }

  try {
    const raw = await request.text()
    if (raw && raw.length < 4000 && raw.startsWith("{")) {
      // eslint-disable-next-line no-console
      console.log("[web-vitals]", raw)
    }
  } catch {
    // Ignore malformed beacons — telemetry must never 500.
  }
  return new Response(null, { status: 204 })
}
