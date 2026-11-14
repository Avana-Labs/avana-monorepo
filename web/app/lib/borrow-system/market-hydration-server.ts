import "server-only"
import type { ConvexHttpClient } from "convex/browser"
import { publicMetadataCache, publicMetadataKey } from "@/app/lib/detail-page/public-metadata-cache"
import { api } from "@/convex/_generated/api"
import { publicConvexClient as convexClient } from "@/app/lib/convex/server-client"
import type { ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import { reportServerFetchFailure, reportServerFetchSuccess } from "@/app/lib/detail-page/report-server-fetch-failure"

export { fetchTokenPrices } from "@/app/lib/prices/server-snapshot"

export async function fetchBorrowPoolDetailHydration(slug: string, route?: string) {
  const client = convexClient()
  if (!client) return null
  const startedAt = Date.now()
  try {
    const result = await client.query(api.detailHydration.getBorrowPoolDetail, { slug })
    reportServerFetchSuccess(
      "fetchBorrowPoolDetailHydration",
      { product: "borrow", route, slug, query: "detailHydration.getBorrowPoolDetail" },
      Date.now() - startedAt,
    )
    return result
  } catch (error) {
    reportServerFetchFailure("fetchBorrowPoolDetailHydration", error, {
      product: "borrow",
      route,
      slug,
      query: "detailHydration.getBorrowPoolDetail",
    })
    return null
  }
}

export async function fetchBorrowAssetDetailHydration(slug: string, route?: string) {
  const client = convexClient()
  if (!client) return null
  const startedAt = Date.now()
  try {
    const result = await client.query(api.detailHydration.getBorrowAssetDetail, { slug })
    reportServerFetchSuccess(
      "fetchBorrowAssetDetailHydration",
      { product: "borrow", route, slug, query: "detailHydration.getBorrowAssetDetail" },
      Date.now() - startedAt,
    )
    return result
  } catch (error) {
    reportServerFetchFailure("fetchBorrowAssetDetailHydration", error, {
      product: "borrow",
      route,
      slug,
      query: "detailHydration.getBorrowAssetDetail",
    })
    return null
  }
}

/**
 * Convex market reference snapshots. Returns [] when unconfigured or unreachable so callers
 * degrade to the catalog base. Detail pages should use `fetchConvexMarketSnapshot` instead;
 * this list path is for catalogs / session hydration.
 */
export async function fetchConvexMarketSnapshots(): Promise<ConvexMarketSnapshot[]> {
  const client = convexClient()
  if (!client) return []
  try {
    return (await client.query(api.markets.listBorrowMarketSnapshots, {})) as ConvexMarketSnapshot[]
  } catch (error) {
    reportServerFetchFailure("fetchConvexMarketSnapshots", error)
    return []
  }
}

/** One slug-scoped borrow pool/asset snapshot for detail builders. */
export async function fetchConvexMarketSnapshot(
  scope: "pool" | "asset",
  slug: string,
): Promise<ConvexMarketSnapshot | null> {
  const client = convexClient()
  if (!client) return null
  try {
    const row = await client.query(api.markets.getMarketSnapshot, { scope, slug })
    return (row as ConvexMarketSnapshot | null) ?? null
  } catch (error) {
    reportServerFetchFailure("fetchConvexMarketSnapshot", error)
    return null
  }
}

export type ConvexSeriesPoint = { t: string; v: number }

/**
 * Row shape from api.contractAddresses.list{Pool,Asset,Multiply}Addresses, mapped 1:1 into
 * AboutCard.stats. `label`/`href` are seeded; `isSynthetic` is seed-sync metadata, unused in UI.
 */
export type ConvexContractAddressRow = {
  salt: string
  address: string
  label: string
  href: string
  chain: string
  isSynthetic: boolean
}

async function fetchContractAddressRows(
  key: string,
  runQuery: (client: ConvexHttpClient) => Promise<unknown>,
): Promise<ConvexContractAddressRow[]> {
  const client = convexClient()
  if (!client) return []
  try {
    const rows = (await publicMetadataCache.get(key, () => runQuery(client))) as ConvexContractAddressRow[] | null
    return rows ?? []
  } catch (error) {
    reportServerFetchFailure("fetchContractAddressRows", error)
    return []
  }
}

/** Pool contract-address rows for detail.about.stats. Empty when Convex is unreachable. */
export async function fetchPoolContractAddresses(poolSlug: string): Promise<ConvexContractAddressRow[]> {
  return fetchContractAddressRows(publicMetadataKey("pool-addresses", poolSlug), (client) =>
    client.query(api.contractAddresses.listPoolAddresses, { poolSlug }),
  )
}

/** Asset contract-address rows for detail.about.stats. */
export async function fetchAssetContractAddresses(assetSlug: string): Promise<ConvexContractAddressRow[]> {
  return fetchContractAddressRows(publicMetadataKey("asset-addresses", assetSlug), (client) =>
    client.query(api.contractAddresses.listAssetAddresses, { assetSlug }),
  )
}

/** Recent market transactions (app transactions first, then chain events). */
export async function fetchRecentTransactions(scope: "pool" | "asset", slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    const rows = await client.query(api.markets.getRecentTransactions, { scope, slug })
    return rows.length > 0 ? rows : null
  } catch (error) {
    reportServerFetchFailure("fetchRecentTransactions", error)
    return null
  }
}

/** Latest risk assessment (Risk Premium card) from product-siloed `borrowRiskAssessments`. */
export async function fetchRisk(_scope: "pool" | "asset", slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.borrow.riskAssessment.getRisk, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchRisk", error)
    return null
  }
}

/** Asset SupplyBorrowCard series from Convex daily tips (null when unseeded). */
export async function fetchSupplyBorrow(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.markets.getSupplyBorrow, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchSupplyBorrow", error)
    return null
  }
}

/** Editorial content (About / FAQs / history) from product-siloed `borrowMarketContent`. */
export async function fetchContent(_scope: "pool" | "asset", slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await publicMetadataCache.get(publicMetadataKey("borrow-content", slug), () =>
      client.query(api.borrow.content.getContent, { slug }),
    )
  } catch (error) {
    reportServerFetchFailure("fetchContent", error)
    return null
  }
}

/** Borrow product Risk Parameters grid (pool/asset). Product-siloed table. */
export async function fetchBorrowRiskParameters(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.borrow.riskParameters.getRiskParameters, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchBorrowRiskParameters", error)
    return null
  }
}

/** Borrow product — risk parameters for many slugs in one round-trip (allocation card). */
export async function fetchBorrowRiskParametersForSlugs(slugs: string[]) {
  const client = convexClient()
  if (!client || slugs.length === 0) return null
  try {
    return await client.query(api.borrow.riskParameters.getRiskParametersForSlugs, { slugs })
  } catch (error) {
    reportServerFetchFailure("fetchBorrowRiskParametersForSlugs", error)
    return null
  }
}

/** Borrow product — Assets You Can Borrow edges for a pool. */
export async function fetchBorrowPoolBorrowables(poolSlug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    const rows = await client.query(api.borrow.poolBorrowables.getPoolBorrowables, { poolSlug })
    return rows.length > 0 ? rows : null
  } catch (error) {
    reportServerFetchFailure("fetchBorrowPoolBorrowables", error)
    return null
  }
}

/** Borrow product — Interest Rate Model for an asset. */
export async function fetchBorrowInterestRateModel(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.borrow.interestRateModel.getInterestRateModel, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchBorrowInterestRateModel", error)
    return null
  }
}

/** Borrow product — Liquidation Risk KPIs for a pool. */
export async function fetchBorrowLiquidationRisk(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.borrow.liquidationRisk.getLiquidationRisk, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchBorrowLiquidationRisk", error)
    return null
  }
}

/** Borrow product — siloed market identity (pool or asset). */
export async function fetchBorrowMarket(slug: string) {
  const client = convexClient()
  if (!client) return null
  try {
    return await client.query(api.borrow.markets.getMarket, { slug })
  } catch (error) {
    reportServerFetchFailure("fetchBorrowMarket", error)
    return null
  }
}
