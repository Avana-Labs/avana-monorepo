import { NextResponse } from "next/server"
import { assertSameOriginRead } from "../_lib/request-guards"

const ENDPOINT = "https://open.er-api.com/v6/latest/USD"
const REVALIDATE_SECONDS = 6 * 60 * 60

export async function GET(request: Request) {
  // Same-origin only, GET-tuned: a browser sends no Origin header on a same-origin
  // GET, so we key off Sec-Fetch-Site (unforgeable, browser-set) and only block a
  // genuine cross-site fetch. The response is cached and cheap, but exposing the
  // route cross-origin lets any site borrow this app's egress for the upstream FX
  // endpoint. (Using assertSameOrigin here — which fails closed on a missing
  // Origin — would 403 the app's own same-origin fetch.)
  if (!assertSameOriginRead(request)) {
    return NextResponse.json({ error: "origin not allowed" }, { status: 403 })
  }

  const res = await fetch(ENDPOINT, {
    cache: "force-cache",
    next: { revalidate: REVALIDATE_SECONDS },
  })

  if (!res.ok) {
    return NextResponse.json({ result: "error", rates: null }, { status: 502 })
  }

  const data = (await res.json()) as { result?: string; rates?: Record<string, number> }
  return NextResponse.json(
    { result: data.result ?? "error", rates: data.rates ?? null },
    {
      headers: {
        "Cache-Control": `public, max-age=${REVALIDATE_SECONDS}, s-maxage=${REVALIDATE_SECONDS}, stale-while-revalidate=${REVALIDATE_SECONDS}`,
      },
    },
  )
}
