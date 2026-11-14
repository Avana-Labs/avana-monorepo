import "server-only"
import { ConvexHttpClient } from "convex/browser"
import { api } from "@/convex/_generated/api"
import type { MultiplyConvexSnapshot } from "@/app/lib/multiply-system/market-hydration"
import type { MultiplyTokenParameterRow } from "@/app/lib/multiply-system/read-model"
import { requestCache } from "@/app/lib/detail-page/request-cache"
import { reportServerFetchFailure, reportServerFetchSuccess } from "@/app/lib/detail-page/report-server-fetch-failure"

/**
 * Server-side Convex fetchers for the multiply detail page + list. Every fetcher degrades to
 * `null`/`[]` when Convex is unconfigured or unreachable, so the page renders off the catalog.
 */

export type { ConvexContractAddressRow, ConvexSeriesPoint } from "@/app/lib/borrow-system/market-hydration-server"
export { fetchMultiplyContractAddresses, fetchTokenPrices } from "@/app/lib/borrow-system/market-hydration-server"

/** Latest-day reference snapshot for a single multiply market. */
type MultiplyMarketSnapshot = {
  slug: string
  suppliedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
}

// One client per request (request-scoped via React.cache); a fresh client per call in the
// non-RSC test runtime.
const convexClient = requestCache((): ConvexHttpClient | null => {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) return null
  try {
    return new ConvexHttpClient(url)
  } catch (error) {
    reportServerFetchFailure("convexClient", error)
    return null
  }
})

export async function fetchMultiplyDetailHydration(slug: string, route?: string) {
  const client = convexClient()
  if (!client) return null
  const startedAt = Date.now()
  try {
    const result = await client.query(api.detailHydration.getMultiplyDetail, { slug })
    reportServerFetchSuccess(
      "fetchMultiplyDetailHydration",
      { product: "multiply", route, slug, query: "detailHydration.getMultiplyDetail" },
      Date.now() - startedAt,
    )
    return result
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyDetailHydration", error, {
      product: "multiply",
      route,
      slug,
      query: "detailHydration.getMultiplyDetail",
    })
    return null
  }
}

/** Latest-day reference snapshot for one multiply market (slug-scoped). */
export async function fetchMultiplyMarketSnapshot(slug: string): Promise<MultiplyMarketSnapshot | null> {
  const client = convexClient()
  if (!client) return null
  try {
    const match = await client.query(api.markets.getMarketSnapshot, { scope: "multiply", slug })
    if (!match) return null
    return {
      slug: match.slug,
      suppliedUsd: match.suppliedUsd,
      availableUsd: match.availableUsd,
      utilizationPct: match.utilizationPct,
      supplyApyPct: match.supplyApyPct,
      borrowAprPct: match.borrowAprPct,
    }
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyMarketSnapshot", error)
    return null
  }
}

/** All multiply-scope latest-day snapshots (for SSR list hydration). [] when unreachable. */
export async function fetchMultiplyMarketSnapshots(): Promise<MultiplyConvexSnapshot[]> {
  const client = convexClient()
  if (!client) return []
  try {
    const rows = await client.query(api.markets.listMultiplyMarketSnapshots, {})
    return rows.map((row) => ({
      slug: row.slug,
      scope: row.scope,
      name: row.name,
      symbol: row.symbol,
      maxLtvPct: row.maxLtvPct,
      reserveFactorPct: row.reserveFactorPct,
      suppliedUsd: row.suppliedUsd,
      borrowedUsd: row.borrowedUsd,
      availableUsd: row.availableUsd,
      utilizationPct: row.utilizationPct,
      supplyApyPct: row.supplyApyPct,
      borrowAprPct: row.borrowAprPct,
    }))
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyMarketSnapshots", error)
    return []
  }
}

/**
 * Live token parameters for SSR — the same rows the client reads via
 * `useQuery(api.multiply.tokenParameters.listTokens)`, so the first paint carries real
 * APYs/logos instead of the bundled static constants. [] when unreachable.
 */
export async function fetchMultiplyTokenParameters(): Promise<MultiplyTokenParameterRow[]> {
  const client = convexClient()
  if (!client) return []
  try {
    const rows = await client.query(api.multiply.tokenParameters.listTokens, {})
    return (rows ?? []) as MultiplyTokenParameterRow[]
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyTokenParameters", error)
    return []
  }
}

/** Recent market transactions (sandbox first, seeded walletEvents fallback). */
export async function fetchMultiplyRecentTransactions(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    const rows = await client.query(api.markets.getRecentTransactions, { scope: "multiply", slug })
    return rows.length > 0 ? rows : null
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyRecentTransactions", error)
    return null
  }
}

/** Latest risk assessment (Risk Premium card) from product-siloed `multiplyRiskAssessments`. */
export async function fetchMultiplyRisk(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.multiply.riskAssessment.getRisk, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyRisk", error)
    return null
  }
}

/** Editorial content (About description/stats/history + FAQs) for a multiply market. */
export async function fetchMultiplyContent(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.multiply.content.getContent, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyContent", error)
    return null
  }
}

/** Multiply product — Risk Parameters for About / Risk Parameters grid. */
export async function fetchMultiplyRiskParameters(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.multiply.riskParameters.getRiskParameters, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyRiskParameters", error)
    return null
  }
}

/** Multiply product — Liquidation Risk KPIs. */
export async function fetchMultiplyLiquidationRisk(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.multiply.liquidationRisk.getLiquidationRisk, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyLiquidationRisk", error)
    return null
  }
}

/** Multiply product — siloed market identity. */
export async function fetchMultiplyMarket(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.multiply.markets.getMarket, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplyMarket", error)
    return null
  }
}

/** Multiply supply/borrow/utilization series (Convex daily rows, "1Y" window). */
export async function fetchMultiplySupplyBorrow(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.markets.getMultiplySupplyBorrow, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchMultiplySupplyBorrow", error)
    return null
  }
}
