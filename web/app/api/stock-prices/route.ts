import { NextResponse } from "next/server"
import { assertSameOriginRead } from "../_lib/request-guards"
import { registryStockPriceIds } from "@/app/lib/tokens/registry"

/**
 * Live tokenized-stock prices — the stock twin of app/api/fx-rates. The sandbox stores everything in
 * USD; tokenized equities have no DefiLlama coverage, so this route fetches a free stock provider
 * server-side and returns `{ TICKER: priceUsd }`, which the client overlays on the canonical store.
 *
 * Provider-agnostic: keyless Yahoo Finance by default (its v8 chart endpoint, no key — like the
 * keyless fx-rates endpoint), or Finnhub when `STOCK_PRICE_API_KEY` is set (key stays server-side).
 * The fixture (price-fixture.ts, seeded from the token registry) is always the fallback, so a failed
 * fetch never leaves a stock unpriced. SpaceX (SPCX) is private and carries no public quote, so it
 * is excluded from the registry's stock ids and never requested.
 */
const REVALIDATE_SECONDS = 5 * 60

// Distinct public tickers to quote (e.g. NVDA, AAPL, …). NVDA and NVDAc share one ticker.
const TICKERS = [...new Set(Object.values(registryStockPriceIds()))].map((ticker) => ticker.toUpperCase())

async function fetchFromYahoo(): Promise<Record<string, number>> {
  // Yahoo's keyless v8 chart endpoint is single-symbol, so fetch the handful in parallel and read
  // meta.regularMarketPrice. A User-Agent header avoids the 403 Yahoo returns to header-less clients.
  const out: Record<string, number> = {}
  await Promise.all(
    TICKERS.map(async (ticker) => {
      try {
        const res = await fetch(`https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?interval=1d&range=1d`, {
          headers: { "User-Agent": "Mozilla/5.0" },
          cache: "force-cache",
          next: { revalidate: REVALIDATE_SECONDS },
        })
        if (!res.ok) return
        const data = (await res.json()) as {
          chart?: { result?: Array<{ meta?: { regularMarketPrice?: number } }> }
        }
        const price = data.chart?.result?.[0]?.meta?.regularMarketPrice
        if (typeof price === "number" && Number.isFinite(price) && price > 0) out[ticker] = price
      } catch {
        // Skip this symbol; the client falls back to the fixture for it.
      }
    }),
  )
  return out
}

async function fetchFromFinnhub(apiKey: string): Promise<Record<string, number>> {
  // Finnhub free tier quotes one symbol per request; a handful of stocks stays well under the limit.
  const out: Record<string, number> = {}
  await Promise.all(
    TICKERS.map(async (ticker) => {
      try {
        const res = await fetch(`https://finnhub.io/api/v1/quote?symbol=${ticker}&token=${apiKey}`, {
          cache: "force-cache",
          next: { revalidate: REVALIDATE_SECONDS },
        })
        if (!res.ok) return
        const data = (await res.json()) as { c?: number }
        if (typeof data.c === "number" && Number.isFinite(data.c) && data.c > 0) out[ticker] = data.c
      } catch {
        // Skip this symbol; the client falls back to the fixture for it.
      }
    }),
  )
  return out
}

export async function GET(request: Request) {
  // Same-origin-only (see fx-rates/route.ts): keeps other sites from borrowing this app's egress.
  if (!assertSameOriginRead(request)) {
    return NextResponse.json({ result: "error", prices: null }, { status: 403 })
  }

  const apiKey = process.env.STOCK_PRICE_API_KEY
  try {
    const prices = apiKey ? await fetchFromFinnhub(apiKey) : await fetchFromYahoo()
    if (Object.keys(prices).length === 0) {
      return NextResponse.json({ result: "error", prices: null }, { status: 502 })
    }
    return NextResponse.json(
      { result: "success", prices },
      {
        headers: {
          "Cache-Control": `public, max-age=${REVALIDATE_SECONDS}, s-maxage=${REVALIDATE_SECONDS}, stale-while-revalidate=${REVALIDATE_SECONDS}`,
        },
      },
    )
  } catch {
    return NextResponse.json({ result: "error", prices: null }, { status: 502 })
  }
}
