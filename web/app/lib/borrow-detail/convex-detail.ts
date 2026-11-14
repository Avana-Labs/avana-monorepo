import "server-only"
import { requestCache as cache } from "@/app/lib/detail-page/request-cache"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import {
  fetchBorrowAssetDetailHydration,
  fetchBorrowPoolDetailHydration,
  type ConvexContractAddressRow,
} from "@/app/lib/borrow-system/market-hydration-server"
import type { PreloadedQuickStatRow } from "@/app/lib/detail-page/apply-preloaded-overlays"
import { emptySeriesFamily, shouldStripMockSeriesForLive } from "@/app/lib/detail-page/strip-mock-series"
import { canonicalPriceMap } from "@/app/lib/prices/canonical"
import { priceKey } from "@/app/lib/prices/format"
import { formatOraclePrice, formatPairRate } from "@/app/lib/borrow-detail/formatters"
import { allocationVenueLabel, formatBpsAsPct } from "@/app/lib/borrow-detail/allocation"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
import { resolveAssetDetailFromState, resolvePoolDetailFromState } from "@/app/lib/borrow-system/read-model"
import { resolveAsset } from "@/app/lib/borrow-detail/asset.mock"
import {
  borrowAssetDetailPath,
  normalizeBorrowAssetRouteId,
  normalizeBorrowMarketRouteId,
} from "@/app/lib/borrow-routes"
import type { BorrowableAssetRef } from "@/app/lib/borrow-detail/cross-market"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { getDefaultWalletProfileId } from "@/app/lib/data/wallet/profiles"
import {
  applyDetailContentOverlay,
  injectBaselinePrice,
  mergeAliasedQuickStats,
} from "@/app/lib/detail-page/live-detail-helpers"
import { QUICK_STAT_ALIASES } from "@/app/lib/detail-page/live-quick-stats"
import { buildMockLiquidationRiskStats } from "@/app/lib/detail-page/liquidation-risk"
import { injectSiloedMarketQuickStats, overlayHeroIdentity } from "@/app/lib/detail-page/siloed-market-overlay"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"
import { shouldFailClosedWithoutSnapshots } from "@/app/lib/borrow-detail/live-fallback"
import { preferLiveOrNull } from "@/app/lib/detail-page/live-fallback"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import {
  ABOUT_CONTRACT_ADDRESS_SALTS,
  aboutContractAddressLabelForSalt,
  isAboutContractAddressStat,
  sortAboutContractAddressRows,
} from "@/app/lib/detail-page/about-contract-addresses"
import type { AllocationRow, AssetDetail, PoolDetail, QuickStat } from "./types"

/**
 * Server-only Convex-hydrated detail builders. The borrow detail pages call these
 * so their numbers come from Convex and match the list/hero:
 *   - reference values (TVL, available, utilization, APY, quick stats) ← Convex snapshot
 *   - HERO chart (pool = TVL / total supplied, asset = total borrows) ← Convex daily series
 *   - engagement (active wallets/sessions) ← Convex walletEvents
 * Each Convex read falls back to the deterministic catalog fixture when
 * unreachable, so the page always renders and the sandbox/demo routes stay
 * stable without pretending the fallback is the live source of truth.
 *
 * Kept OUT of `./index.ts` because that module is also imported by client
 * components, and `market-hydration-server.ts` is `server-only`.
 */
const detailWalletId = getDefaultWalletProfileId()

/**
 * Convex `getQuickStats` emits supplied/borrowed/utilization/supplyApy/borrowApy.
 * Pool pages still use totalSupplied/totalBorrowed/apr; asset pages now follow the
 * lend headline set (available/supplyApy/borrowApy), so unused Convex ids no-op.
 */
/**
 * Overlay Convex Market-overview quick stats onto the mock headline numbers,
 * keeping mock-only stats (price, rewards, reserve factor, risk exposure) intact.
 * Alias map is the single source in live-quick-stats.ts (shared with the client live grid).
 */
function mergeConvexQuickStats(
  base: QuickStat[],
  convex: ReadonlyArray<{ id: string; value: string; delta?: QuickStat["delta"] }> | null,
): QuickStat[] {
  return mergeAliasedQuickStats(base, convex, QUICK_STAT_ALIASES.borrow)
}

/**
 * Overlay the pool "Price" quick stat with the base asset's USD price (price0) from the
 * canonical per-token prices — a real USD value, NOT the base-in-quote pair ratio.
 *
 * The pair ratio (price0 / price1) is only a USD price when the quote is a USD-pegged asset;
 * for a pool like cbBTC / WETH it is the cross rate (~33.7 WETH per cbBTC), which shown with a
 * "$" prefix reads as a bogus "$33.75" instead of cbBTC's true ~$64k. Showing price0 gives the
 * correct USD figure for every pool and is unchanged for USD-quoted pools (price1 ≈ 1, so
 * price0/price1 ≈ price0). The pair exchange rate still belongs on a dedicated rate line, not
 * on a "$"-formatted USD stat. Both legs must be priced (a fully-priced pool); otherwise the
 * stat is DROPPED rather than surfacing the fabricated mock fallback.
 */
export function injectPoolOraclePrice(
  quickStats: QuickStat[],
  prices: Record<string, number> | null,
  symbol0: string,
  symbol1: string,
): QuickStat[] {
  const p0 = prices?.[priceKey(symbol0)]
  const p1 = prices?.[priceKey(symbol1)]
  if (p0 === undefined || p1 === undefined || p1 === 0) {
    return quickStats.filter((s) => s.id !== "price" && s.id !== "oraclePrice")
  }
  // Pool price = the pair spot rate: the base leg priced in the QUOTE leg's units (not USD), so
  // it differs per pool (cbBTC/WETH ≈ 33.7 WETH vs cbBTC/USDC ≈ 64k USDC) and never mislabels a
  // non-USD rate with a "$". The tooltip carries the Uniswap-style reference with the USD value.
  const rate = p0 / p1
  const value = `${formatPairRate(rate)} ${symbol1}`
  const tooltip =
    `1 ${symbol0} = ${formatPairRate(rate)} ${symbol1} (${formatOraclePrice(p0)}) — the pair spot rate, ` +
    `P(${symbol0}) ÷ P(${symbol1}) from the oracle, with the USD value of ${symbol0} shown in parentheses.`
  return quickStats.map((s) => (s.id === "price" || s.id === "oraclePrice" ? { ...s, value, tooltip } : s))
}

/**
 * Restate the "Risk premium" quick stat (Market data > Risk exposure) from the SAME
 * premium the Risk assessment card renders (detail.risk.premiumBps), so a page never
 * shows two different values for the one metric. The mock quick stat comes from the
 * catalog row while risk is overlaid from Convex; without this they can disagree.
 */
export function syncQuickStatsRiskPremium(quickStats: QuickStat[], premiumBps: number): QuickStat[] {
  const value = formatBpsAsPct(premiumBps)
  return quickStats.map((s) => (s.id === "riskPremium" ? { ...s, value } : s))
}

/**
 * Derive the asset `historicalUtilization` series from the `supplyBorrow` utilization series.
 *
 * `getHistoricalUtilization` used to read a SECOND, identical 1Y window of the same asset's
 * daily rows just to project `utilizationPct` — the exact series `getSupplyBorrow` already
 * builds from those same rows. Convex reported both queries at 16.6 MB: the same bytes,
 * twice, on every asset detail render. The points are identical, so only the id suffix is
 * restated, keeping downstream series keys byte-for-byte what they were.
 */
export function deriveHistoricalUtilization<T extends { id: string }>(utilization: T | null | undefined): T | null {
  if (!utilization) return null
  return { ...utilization, id: utilization.id.replace(/:sb:utilization$/, ":historical-utilization") }
}

/**
 * Fail-closed empty defaults used when a Convex query returns null. These stand in for
 * the removed nullish-mock cascades — the mock's shape survives (so UI type contracts
 * hold) but none of its VALUES leak into the hydrated detail. Each shape is the minimal
 * that makes the corresponding UI section render empty (no rows, no bars).
 */
const EMPTY_CASHFLOW_CARD: import("./types").CashflowCard = { bars: [], rows: [], periodLabel: "" }
const EMPTY_CASHFLOW_TREND: import("./types").CashflowTrend = {
  totalLabel: "",
  periodLabel: "",
  series: { id: "cashflow-trend", label: "", points: [] },
}
const EMPTY_SERIES = { id: "empty", label: "", points: [] }
const EMPTY_SUPPLY_BORROW = {
  supplied: { id: "supplied", label: "Supplied", points: [] },
  borrowed: { id: "borrowed", label: "Borrowed", points: [] },
  utilization: { id: "utilization", label: "Utilization", points: [] },
}

function mapConvexBorrowables(
  rows: ReadonlyArray<{ id: string; name: string; symbol: string; borrowAprPct: number }> | null,
): BorrowableAssetRef[] | undefined {
  if (!rows || rows.length === 0) return undefined
  const byId = new Map(listSpokeBorrowables().map((asset) => [asset.id, asset]))
  return rows.map((row) => {
    const asset = byId.get(row.id)
    return {
      id: row.id,
      name: row.name,
      symbol: row.symbol,
      visual: asset?.visual ?? {
        symbol: row.symbol,
        shortLabel: row.symbol.slice(0, 1),
        bgClass: "bg-muted",
        textClass: "text-foreground",
      },
      apy: row.borrowAprPct,
      // Convex poolBorrowables carries no liquidity, so pull the supply-side TVL from the
      // catalog asset (borrowed + available) for the "… Supply" sub-label.
      tvlUsd: asset ? asset.totalBorrowedUsd + asset.availableUsd : undefined,
      href: borrowAssetDetailPath(row.id),
    }
  })
}

function collateralFactorFromRiskParameters(
  parameters: ReadonlyArray<{ id: string; value: string }> | null | undefined,
): number | undefined {
  const raw = parameters?.find((parameter) => parameter.id === "collateralFactor")?.value
  if (!raw) return undefined
  const numeric = Number.parseFloat(raw.replace(/[^0-9.-]/g, ""))
  return Number.isFinite(numeric) ? numeric : undefined
}

function hydrateAllocationRows(
  rows:
    | ReadonlyArray<{
        poolSlug: string
        poolName: string
        venueLabel: string
        sharePct: number
        valueUsd: number
        utilizationPct: number
        borrowAprPct: number
      }>
    | null
    | undefined,
  assetId: string,
): AllocationRow[] | null {
  if (!rows || rows.length === 0) return null
  const hydrated = rows.flatMap((row) => {
    const pool = BORROW_POOL_CATALOG.find((candidate) => candidate.id === row.poolSlug)
    if (!pool) return []
    return [
      {
        id: `${assetId}-${row.poolSlug}`,
        poolName: row.poolName,
        venueLabel: allocationVenueLabel(pool),
        visuals: pool.visuals,
        sharePct: row.sharePct,
        valueUsd: row.valueUsd,
        utilizationPct: row.utilizationPct,
        borrowAprPct: row.borrowAprPct,
        feeTier: pool.feeTier,
        tvlUsd: pool.tvlUsd,
      },
    ]
  })
  return hydrated.length > 0 ? hydrated : null
}

async function enrichAllocationWithCollateralFactors(
  allocation: AllocationRow[] | null,
  assetId: string,
  preloadedRiskRows?: ReadonlyArray<{ slug: string; parameters: ReadonlyArray<{ id: string; value: string }> }> | null,
): Promise<AllocationRow[] | null> {
  if (!allocation || allocation.length === 0) return allocation
  const riskRows = preloadedRiskRows ?? []
  const cfByPool = new Map<string, number>()
  for (const row of riskRows ?? []) {
    const cf = collateralFactorFromRiskParameters(row.parameters)
    if (cf !== undefined) cfByPool.set(row.slug, cf)
  }
  if (cfByPool.size === 0) return allocation
  return allocation.map((row) => {
    const prefix = `${assetId}-`
    const poolSlug = row.id.startsWith(prefix) ? row.id.slice(prefix.length) : row.id
    const collateralFactorPct = cfByPool.get(poolSlug)
    return collateralFactorPct === undefined ? row : { ...row, collateralFactorPct }
  })
}

/**
 * Contract-address rows for the About card. Maps Convex salt → display label
 * (vault / token / riskManager / oracleRouter). Labels live in
 * `about-contract-addresses.ts` so seed, inject, and the (i) help stay aligned.
 */
const CONTRACT_ADDRESS_SALTS = new Set<string>(ABOUT_CONTRACT_ADDRESS_SALTS)

function contractRowToStat(row: ConvexContractAddressRow): { label: string; value: string; href: string } {
  return {
    label: aboutContractAddressLabelForSalt(row.salt) ?? row.label,
    value: row.label,
    href: row.href,
  }
}

/**
 * Replace (not append) the About card's contract-address rows with the canonical
 * Vault / Token / Risk Manager / Oracle Router set from Convex. Stripping any
 * pre-existing contract rows first makes this idempotent against stale/double-seeded
 * `content.stats` (including legacy Staking rows), so the card always shows exactly
 * four. When Convex has no rows (offline), leave the seeded stats untouched.
 */
function injectContractAddressStats<T extends { about: AssetDetail["about"] | PoolDetail["about"] }>(
  detail: T,
  rows: readonly ConvexContractAddressRow[],
): T {
  const contractRows = sortAboutContractAddressRows(rows.filter((row) => CONTRACT_ADDRESS_SALTS.has(row.salt)))
  if (contractRows.length === 0) return detail
  const seen = new Set<string>()
  const contractStats: Array<{ label: string; value: string; href: string }> = []
  for (const stat of contractRows.map(contractRowToStat)) {
    if (seen.has(stat.label)) continue
    seen.add(stat.label)
    contractStats.push(stat)
  }
  return {
    ...detail,
    about: {
      ...detail.about,
      stats: [...detail.about.stats.filter((stat) => !isAboutContractAddressStat(stat)), ...contractStats],
    },
  }
}

function applyRiskParametersToAbout<T extends { about: AssetDetail["about"] | PoolDetail["about"] }>(
  detail: T,
  riskParameters:
    { parameters: Array<{ id: string; label: string; value: string; description?: string }> } | null | undefined,
): T {
  if (!riskParameters?.parameters.length) return detail
  return {
    ...detail,
    about: {
      ...detail.about,
      governanceParameters: {
        parameters: riskParameters.parameters.map((parameter) => ({
          id: parameter.id,
          label: parameter.label,
          value: parameter.value,
          description: parameter.description,
        })),
        changelog: detail.about.governanceParameters?.changelog ?? [],
      },
    },
  }
}

async function getPoolDetailFromConvexUncached(id: string): Promise<PoolDetail | null> {
  const routeId = normalizeBorrowMarketRouteId(id)
  const state = buildMockBorrowSystemState(detailWalletId)
  // Resolve against catalog first so we know the Convex slug without pulling every snapshot.
  const catalogDetail = resolvePoolDetailFromState(state, detailWalletId, routeId)
  if (!catalogDetail) return null

  const mode = resolveDataSourceMode()
  const poolId = catalogDetail.row.id
  // Hero / quick-stats / cashflow are preloaded on the page (preloadQuery) and merged
  // via applyPoolPreloadedOverlays — do not HTTP-fetch those queries here (C03).
  // The snapshot rides in the same batch: every key is the catalog pool id, so waiting for
  // it first only added a Convex round trip to every pool detail SSR.
  const hydration = await fetchBorrowPoolDetailHydration(poolId, `/borrow/markets/${id}`)
  const {
    snapshot,
    transactions,
    risk,
    content,
    riskParameters,
    poolBorrowables = [],
    liquidationRisk,
    siloedMarket,
    contractAddresses = [],
  } = hydration ?? {}
  const snap = snapshot?.scope === "pool" ? (snapshot as ConvexMarketSnapshot) : null
  if (shouldFailClosedWithoutSnapshots(mode, snap ? 1 : 0)) return null
  const hydratedState = snap ? mergeConvexMarketSnapshots(state, [snap]) : state
  const detail = resolvePoolDetailFromState(hydratedState, detailWalletId, routeId)
  if (!detail) return null
  // Capacity labels are now sourced solely from borrowRiskParameters (Convex-seeded
  // via borrowPoolCapacityLabels at seed time). Read-time overlay removed — it re-applied
  // the same 1.75×/2.25× heuristic on top of the already-seeded value, silently masking
  // any real cap change and giving devs two things to keep in sync.
  //
  // getQuickStats already emits `available` and `reserveFactor` directly, so the two
  // per-stat overlays that used to layer them on top of the Convex quickStats have been
  // deleted. premiumBps flows from Convex risk when present, else 0 (fail-closed).
  const convexRisk = (risk as typeof detail.risk | null) ?? null
  const baseQuickStats = syncQuickStatsRiskPremium(
    injectSiloedMarketQuickStats(
      injectPoolOraclePrice(
        detail.quickStats,
        canonicalPriceMap(),
        detail.row.visuals[0].symbol,
        detail.row.visuals[1].symbol,
      ),
      siloedMarket,
    ),
    convexRisk?.premiumBps ?? 0,
  )
  const hydrated = applyDetailContentOverlay(
    {
      ...detail,
      quickStats: baseQuickStats,
      // heroFeed / heroBorrowedFeed / heroUtilizationFeed are set by the page from the
      // preloaded hero series (preloadPoolHero), not built here.
      // cashflow filled by applyPoolPreloadedOverlays from the page preload (C03).
      cashflow: EMPTY_CASHFLOW_CARD,
      transactions: (transactions as typeof detail.transactions | null) ?? [],
      risk: convexRisk ?? EMPTY_RISK_ASSESSMENT,
      borrowableAssets: mapConvexBorrowables(poolBorrowables),
      // Fail closed in live: never fabricate liquidation KPIs. When Convex has no
      // liquidation rows the card renders its empty state (the client guards on
      // length); the PRNG mock stays reserved for the demo catalog (mock mode).
      liquidationRisk:
        preferLiveOrNull(
          mode,
          liquidationRisk?.stats?.length ? liquidationRisk.stats : null,
          detail.liquidationRisk ?? buildMockLiquidationRiskStats(detail.row.id),
        ) ?? [],
    },
    content,
    { clearWhenMissing: mode === "live" },
  )

  const withIdentity = injectContractAddressStats(
    {
      ...hydrated,
      hero: overlayHeroIdentity(hydrated.hero, siloedMarket),
    },
    contractAddresses,
  )

  const stripped = stripPoolHeroMetricSeriesForLive(withIdentity)
  if (!riskParameters?.parameters.length) return stripped
  return applyRiskParametersToAbout(stripped, riskParameters)
}

async function getAssetDetailFromConvexUncached(id: string): Promise<AssetDetail | null> {
  const routeSlug = normalizeBorrowAssetRouteId(id)
  // The route id may be a BASE-asset id ("usdc") or a spoke-scoped id ("uni-v2:usdc").
  // Convex markets are keyed by the spoke-scoped id, so resolve to the canonical
  // record and query Convex by ITS id — otherwise a base id finds no Convex market and
  // the hero/quick-stats fall back to a random mock feed (the "$65K total borrows" bug).
  const record = resolveAsset(routeSlug)
  if (!record) return null
  const slug = record.id

  // Hero / quick-stats / cashflow preloaded on the page — not fetched here (C03).
  //
  // cashflowTrend is NOT fetched: `borrow.cashflow.getRevenueForAsset` re-read the same
  // `borrowRevenueDaily` window as the preloaded breakdown (Convex billed both at 20.19 MB)
  // and no component renders the result — the field is written here and read nowhere. The
  // shape stays on AssetDetail because schema.ts still documents it as an asset-page
  // surface; restore the fetch here when something actually renders it.
  // The snapshot rides in the same batch: every key is the catalog slug, so waiting for it
  // first only added a Convex round trip to every asset detail SSR.
  const hydration = await fetchBorrowAssetDetailHydration(slug, `/borrow/assets/${id}`)
  const {
    snapshot,
    supplyBorrow,
    transactions,
    allocation = [],
    allocationRiskParameters = null,
    risk,
    content,
    riskParameters,
    interestRateModel,
    siloedMarket,
    contractAddresses = [],
  } = hydration ?? {}
  const snap = snapshot?.scope === "asset" ? (snapshot as ConvexMarketSnapshot) : null
  if (shouldFailClosedWithoutSnapshots(resolveDataSourceMode(), snap ? 1 : 0)) return null
  const detail = resolveAssetDetailFromState(
    slug,
    snap
      ? {
          availableUsd: snap.availableUsd,
          totalBorrowedUsd: snap.borrowedUsd,
          utilization: snap.utilizationPct,
          borrowApr: snap.borrowAprPct,
        }
      : undefined,
  )
  if (!detail) return null

  const historicalUtilization = deriveHistoricalUtilization(supplyBorrow?.utilization)

  const allocationRows = hydrateAllocationRows(allocation, slug)
  const allocationWithCf = await enrichAllocationWithCollateralFactors(allocationRows, slug, allocationRiskParameters)

  const hydrated = applyDetailContentOverlay(
    {
      ...detail,
      quickStats: injectSiloedMarketQuickStats(
        injectBaselinePrice(detail.quickStats, record.baseAssetId),
        siloedMarket,
      ),
      // heroFeed / heroBorrowedFeed / heroUtilizationFeed set by the page from preloadAssetHero.
      supplyBorrow: (supplyBorrow as typeof detail.supplyBorrow | null) ?? EMPTY_SUPPLY_BORROW,
      historicalUtilization: (historicalUtilization as typeof detail.historicalUtilization | null) ?? EMPTY_SERIES,
      cashflow: EMPTY_CASHFLOW_CARD,
      cashflowTrend: EMPTY_CASHFLOW_TREND,
      transactions: (transactions as typeof detail.transactions | null) ?? [],
      allocation: (allocationWithCf as typeof detail.allocation | null) ?? [],
      risk: (risk as typeof detail.risk | null) ?? EMPTY_RISK_ASSESSMENT,
      interestRateModel: interestRateModel
        ? {
            utilizationPct: interestRateModel.utilizationPct,
            borrowAprPct: interestRateModel.borrowAprPct,
            optimalUtilizationPct: interestRateModel.optimalUtilizationPct,
            slopeBelowOptimalPct: interestRateModel.slopeBelowOptimalPct,
            slopeAboveOptimalPct: interestRateModel.slopeAboveOptimalPct,
            baseBorrowRatePct: interestRateModel.baseBorrowRatePct,
          }
        : undefined,
    },
    content,
    { clearWhenMissing: resolveDataSourceMode() === "live" },
  )

  return applyRiskParametersToAbout(
    stripAssetHeroMetricSeriesForLive(
      injectContractAddressStats(
        {
          ...hydrated,
          hero: overlayHeroIdentity(hydrated.hero, siloedMarket),
        },
        contractAddresses,
      ),
    ),
    riskParameters,
  )
}

function stripPoolHeroMetricSeriesForLive(detail: PoolDetail): PoolDetail {
  if (!shouldStripMockSeriesForLive()) return detail
  return {
    ...detail,
    heroMetric: {
      ...detail.heroMetric,
      series: {
        tvl: emptySeriesFamily(`${detail.row.id}:tvl`, "Supplied"),
        borrowed: emptySeriesFamily(`${detail.row.id}:borrowed`, "Borrowed"),
        utilization: emptySeriesFamily(`${detail.row.id}:utilization`, "Utilization"),
      },
    },
  }
}

function stripAssetHeroMetricSeriesForLive(detail: AssetDetail): AssetDetail {
  if (!shouldStripMockSeriesForLive()) return detail
  return {
    ...detail,
    heroMetric: {
      ...detail.heroMetric,
      series: {
        price: emptySeriesFamily(`${detail.id}:price`, "Price"),
        supply: emptySeriesFamily(`${detail.id}:supply`, "Total Supplied"),
        borrow: emptySeriesFamily(`${detail.id}:borrow`, "Total Borrowed"),
        utilization: emptySeriesFamily(`${detail.id}:util`, "Utilization"),
        apy: emptySeriesFamily(`${detail.id}:apy`, "Borrow APY"),
      },
    },
  }
}

// Request-scoped memoization keeps these builders safe if the route is rendered more
// than once during the same RSC request. Metadata uses the static catalog and does
// not invoke this live fan-out.
export const getPoolDetailFromConvex = cache(getPoolDetailFromConvexUncached)
export const getAssetDetailFromConvex = cache(getAssetDetailFromConvexUncached)

/**
 * Merge page `preloadQuery` results for quick stats + cashflow onto a builder detail.
 * Re-applies pool oracle price + risk-premium sync after the Convex merge (C03).
 */
export function applyPoolPreloadedOverlays(
  detail: PoolDetail,
  overlays: {
    quickStats?: ReadonlyArray<PreloadedQuickStatRow> | null
    cashflow?: PoolDetail["cashflow"] | null
  },
): PoolDetail {
  const quickStats =
    overlays.quickStats != null
      ? syncQuickStatsRiskPremium(
          injectPoolOraclePrice(
            mergeConvexQuickStats(detail.quickStats, overlays.quickStats),
            canonicalPriceMap(),
            detail.row.visuals[0].symbol,
            detail.row.visuals[1].symbol,
          ),
          detail.risk?.premiumBps ?? 0,
        )
      : detail.quickStats
  return {
    ...detail,
    quickStats,
    cashflow: overlays.cashflow ?? detail.cashflow,
  }
}

/** Same as applyPoolPreloadedOverlays for asset details (baseline price, not pair rate). */
export function applyAssetPreloadedOverlays(
  detail: AssetDetail,
  overlays: {
    quickStats?: ReadonlyArray<PreloadedQuickStatRow> | null
    cashflow?: AssetDetail["cashflow"] | null
    /** Base asset id for injectBaselinePrice (e.g. record.baseAssetId). */
    baselinePriceSymbol: string
  },
): AssetDetail {
  const quickStats =
    overlays.quickStats != null
      ? injectBaselinePrice(mergeConvexQuickStats(detail.quickStats, overlays.quickStats), overlays.baselinePriceSymbol)
      : detail.quickStats
  return {
    ...detail,
    quickStats,
    cashflow: overlays.cashflow ?? detail.cashflow,
  }
}
