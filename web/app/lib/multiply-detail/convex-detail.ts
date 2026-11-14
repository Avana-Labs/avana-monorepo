import "server-only"
import { requestCache as cache } from "@/app/lib/detail-page/request-cache"
import {
  fetchMultiplyDetailHydration,
  type ConvexContractAddressRow,
} from "@/app/lib/multiply-system/market-hydration-server"
import type { PreloadedQuickStatRow } from "@/app/lib/detail-page/apply-preloaded-overlays"
import {
  applyDetailContentOverlay,
  injectBaselinePrice,
  mergeAliasedQuickStats,
} from "@/app/lib/detail-page/live-detail-helpers"
import { QUICK_STAT_ALIASES } from "@/app/lib/detail-page/live-quick-stats"
import { buildMockLiquidationRiskStats } from "@/app/lib/detail-page/liquidation-risk"
import {
  injectAvailableUsdQuickStat,
  injectSiloedMarketQuickStats,
  overlayHeroIdentity,
} from "@/app/lib/detail-page/siloed-market-overlay"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"
import { preferLiveOrNull, shouldFailClosedInLive } from "@/app/lib/detail-page/live-fallback"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import {
  ABOUT_CONTRACT_ADDRESS_SALTS,
  aboutContractAddressLabelForSalt,
  isAboutContractAddressStat,
  sortAboutContractAddressRows,
} from "@/app/lib/detail-page/about-contract-addresses"
import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { getMultiplyMarketDetail, withLiveMultiplyRates } from "./index"
import type { MultiplyMarketDetail, MultiplyTxHistoryRow } from "./index"
import type { QuickStat } from "@/app/lib/borrow-detail"

/**
 * Server-only Convex-hydrated multiply detail builder.
 */

function mergeConvexQuickStats(
  base: QuickStat[],
  convex: ReadonlyArray<{ id: string; value: string; delta?: QuickStat["delta"] }> | null,
): QuickStat[] {
  return mergeAliasedQuickStats(base, convex, QUICK_STAT_ALIASES.multiply)
}

function applyRiskParametersToAbout(
  detail: MultiplyMarketDetail,
  riskParameters:
    { parameters: Array<{ id: string; label: string; value: string; description?: string }> } | null | undefined,
): MultiplyMarketDetail {
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

/**
 * Same four salts as the pool/asset overlays (vault / token / riskManager / oracleRouter),
 * keyed by `salt` so the display label stays derived from the Convex row's classification.
 */
const MULTIPLY_CONTRACT_SALTS = new Set<string>(ABOUT_CONTRACT_ADDRESS_SALTS)

/**
 * Replace (not append) the About card's contract-address rows with the canonical four
 * from Convex. Multiply seeded these into BOTH `content.stats` and the contract-address
 * table, so the old append produced exact duplicates. Stripping existing contract rows
 * first (including legacy Staking) makes it idempotent — always exactly four.
 */
function injectMultiplyContractAddressStats(
  detail: MultiplyMarketDetail,
  rows: readonly ConvexContractAddressRow[],
): MultiplyMarketDetail {
  const contractRows = sortAboutContractAddressRows(rows.filter((row) => MULTIPLY_CONTRACT_SALTS.has(row.salt)))
  if (contractRows.length === 0) return detail
  const seen = new Set<string>()
  const contractStats: Array<{ label: string; value: string; href: string }> = []
  for (const row of contractRows) {
    const label = aboutContractAddressLabelForSalt(row.salt) ?? row.label
    if (seen.has(label)) continue
    seen.add(label)
    contractStats.push({ label, value: row.label, href: row.href })
  }
  return {
    ...detail,
    about: {
      ...detail.about,
      stats: [...detail.about.stats.filter((stat) => !isAboutContractAddressStat(stat)), ...contractStats],
    },
  }
}

async function getMultiplyMarketDetailFromConvexUncached(id: string): Promise<MultiplyMarketDetail | null> {
  const detail = getMultiplyMarketDetail(id)
  if (!detail) return null
  const slug = detail.id

  // Supply hero / quick-stats / cashflow preloaded on the page — not fetched here (C03).
  const hydration = await fetchMultiplyDetailHydration(slug, `/multiply/markets/${id}`)
  const {
    transactions,
    risk,
    content,
    riskParameters,
    liquidationRisk,
    siloedMarket,
    snapshot,
    supplyBorrow,
    contractAddresses = [],
  } = hydration ?? {}
  // Fail closed in live mode when Convex has no snapshot — matches borrow detail
  // so the page never silently renders the mock catalog next to an empty live list.
  const mode = resolveDataSourceMode()
  if (shouldFailClosedInLive(mode, snapshot != null)) return null

  const hydrated = applyDetailContentOverlay(
    {
      ...detail,
      quickStats: injectSiloedMarketQuickStats(
        injectAvailableUsdQuickStat(
          injectBaselinePrice(detail.quickStats, detail.row.protocol),
          snapshot?.availableUsd,
          formatCompactUsd,
        ),
        siloedMarket,
      ),
      // heroFeed set by the page from preloadMultiplyHero.
      cashflow: { bars: [], rows: [], periodLabel: "" },
      // Fail closed in live: empty (not the catalog copy) when Convex has no rows.
      // The client overlays the wallet's own session transactions on top of this.
      transactions:
        preferLiveOrNull(mode, (transactions as MultiplyTxHistoryRow[] | null) ?? null, detail.transactions) ?? [],
      risk: preferLiveOrNull(mode, risk as typeof detail.risk | null, detail.risk) ?? EMPTY_RISK_ASSESSMENT,
      // Fail closed in live: never fabricate liquidation KPIs (see borrow detail).
      liquidationRisk:
        preferLiveOrNull(
          mode,
          liquidationRisk?.stats?.length ? liquidationRisk.stats : null,
          detail.liquidationRisk ?? buildMockLiquidationRiskStats(slug),
        ) ?? [],
      // Fail closed: when Convex has no rows the section stays empty rather than
      // reusing the PRNG mock in `detail.supplyBorrow`. Empty series render as no
      // points and the hero chart falls back to its own downstream local feed.
      supplyBorrow: supplyBorrow ?? buildEmptySupplyBorrow(slug),
    },
    content,
    { clearWhenMissing: mode === "live" },
  )

  const withRiskParameters = applyRiskParametersToAbout(
    injectMultiplyContractAddressStats(
      {
        ...hydrated,
        hero: overlayHeroIdentity(hydrated.hero, siloedMarket),
      },
      contractAddresses,
    ),
    riskParameters,
  )
  return withLiveMultiplyRates(withRiskParameters, snapshot)
}

/**
 * Empty supply/borrow/utilization triple used when the Convex query returns null.
 * The page's fail-closed contract: the section stays empty (no points) rather than
 * reusing the mock PRNG series from `getMultiplyMarketDetail`.
 */
function buildEmptySupplyBorrow(slug: string): MultiplyMarketDetail["supplyBorrow"] {
  return {
    supplied: { id: `${slug}:sb:supplied`, label: "Supplied", points: [] },
    borrowed: { id: `${slug}:sb:borrowed`, label: "Borrowed", points: [] },
    utilization: { id: `${slug}:sb:utilization`, label: "Utilization", points: [] },
  }
}

// Request-scoped memoization keeps the detail builder safe if the route is rendered
// more than once during the same RSC request.
export const getMultiplyMarketDetailFromConvex = cache(getMultiplyMarketDetailFromConvexUncached)

/** Merge page preloadQuery results onto multiply detail (C03 — avoid double HTTP fetch). */
export function applyMultiplyPreloadedOverlays(
  detail: MultiplyMarketDetail,
  overlays: {
    quickStats?: ReadonlyArray<PreloadedQuickStatRow> | null
    cashflow?: MultiplyMarketDetail["cashflow"] | null
    baselinePriceSymbol: string
  },
): MultiplyMarketDetail {
  const quickStats =
    overlays.quickStats != null
      ? injectBaselinePrice(mergeConvexQuickStats(detail.quickStats, overlays.quickStats), overlays.baselinePriceSymbol)
      : detail.quickStats
  // Supply/Borrow APY live on Market Rates now; reuse the same getQuickStats alias map.
  const marketRates =
    overlays.quickStats != null ? mergeConvexQuickStats(detail.marketRates, overlays.quickStats) : detail.marketRates
  return {
    ...detail,
    quickStats,
    marketRates,
    cashflow: overlays.cashflow ?? detail.cashflow,
  }
}
