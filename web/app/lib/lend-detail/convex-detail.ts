import "server-only"
import { requestCache as cache } from "@/app/lib/detail-page/request-cache"
import { fetchLendDetailHydration } from "@/app/lib/lend-system/market-hydration-server"
import type { PreloadedQuickStatRow } from "@/app/lib/detail-page/apply-preloaded-overlays"
import { emptySeries, shouldStripMockSeriesForLive } from "@/app/lib/detail-page/strip-mock-series"
import {
  applyDetailContentOverlay,
  injectBaselinePrice,
  mergeAliasedQuickStats,
} from "@/app/lib/detail-page/live-detail-helpers"
import { QUICK_STAT_ALIASES } from "@/app/lib/detail-page/live-quick-stats"
import { injectSiloedMarketQuickStats, overlayHeroIdentity } from "@/app/lib/detail-page/siloed-market-overlay"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"
import { preferLiveOrNull, shouldFailClosedInLive } from "@/app/lib/detail-page/live-fallback"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import { warnLiveFallback } from "@/app/lib/data/providers/hydration-telemetry"
import {
  ABOUT_CONTRACT_ADDRESS_SALTS,
  aboutContractAddressLabelForSalt,
  isAboutContractAddressStat,
  sortAboutContractAddressRows,
} from "@/app/lib/detail-page/about-contract-addresses"
import { resolveLendHeadlineRates } from "./headline-rates"
import type { ProtocolParameterRow } from "@/app/lib/borrow-detail/protocol-parameters"
import { alignRiskSupplyApyMetric, buildLendMarketDetail, resolveLendMarket } from "./mock"
import type { LendMarketDetail } from "./types"
import type { QuickStat } from "@/app/lib/borrow-detail"
import { formatPercent } from "@/app/lib/format"

/**
 * Server-only Convex-hydrated lend detail builder. The lend detail page calls this
 * so its numbers come from Convex and match the list/hero:
 *   - reference values (supplied / borrowed / utilization / APY) ← Convex snapshot
 *   - HERO chart (total supplied)                                ← Convex daily series
 *   - engagement / cashflow / risk / about / faqs / transactions ← Convex queries
 *   - risk parameters / IRM                                      ← lend* product silos
 *   - "Price" quick stat                                         ← deterministic sandbox baseline
 * Each Convex read falls back to the catalog/mock value when unreachable, so the
 * page always renders. Kept OUT of `./index.ts` because that barrel is also imported
 * by client components and `market-hydration-server.ts` is `server-only`.
 */

/** Convex `getQuickStats` emits asset-style ids; map each to the mock ids it overrides. */
function mergeConvexQuickStats(
  base: QuickStat[],
  convex: ReadonlyArray<{ id: string; value: string; delta?: QuickStat["delta"] }> | null,
): QuickStat[] {
  return mergeAliasedQuickStats(base, convex, QUICK_STAT_ALIASES.lend)
}

function irmProtocolParameters(irm: {
  optimalUtilizationPct: number
  slopeBelowOptimalPct: number
  slopeAboveOptimalPct: number
  baseBorrowRatePct: number
}): ProtocolParameterRow[] {
  return [
    { id: "optimalUtilization", label: "Optimal utilization", value: formatPercent(irm.optimalUtilizationPct) },
    { id: "slopeBelowOptimal", label: "Slope below optimal", value: formatPercent(irm.slopeBelowOptimalPct) },
    { id: "slopeAboveOptimal", label: "Slope above optimal", value: formatPercent(irm.slopeAboveOptimalPct) },
    { id: "baseBorrowRate", label: "Base borrow rate", value: formatPercent(irm.baseBorrowRatePct) },
  ]
}

function applyRiskParametersToAbout(
  detail: LendMarketDetail,
  riskParameters:
    { parameters: Array<{ id: string; label: string; value: string; description?: string }> } | null | undefined,
): LendMarketDetail {
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

const LEND_CONTRACT_SALTS = new Set<string>(ABOUT_CONTRACT_ADDRESS_SALTS)

/**
 * Replace About contract-address rows with the canonical four from Convex
 * `lendContractAddresses` — same inject path as borrow/multiply.
 */
function injectLendContractAddressStats(
  detail: LendMarketDetail,
  rows: ReadonlyArray<{ salt: string; label: string; href: string }>,
): LendMarketDetail {
  const contractRows = sortAboutContractAddressRows(rows.filter((row) => LEND_CONTRACT_SALTS.has(row.salt)))
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

async function getLendMarketDetailFromConvexUncached(id: string): Promise<LendMarketDetail | null> {
  const market = resolveLendMarket(id)
  if (!market) return null
  const slug = market.marketId

  const mode = resolveDataSourceMode()
  // Supply hero / quick-stats / cashflow preloaded on the page — not fetched here (C03).
  // supplyBorrow from Convex replaces PRNG series on the live path (C05).
  // The snapshot rides in the same batch: every key here comes from the catalog slug, so
  // waiting for it first only added a Convex round trip to every detail SSR.
  const hydration = await fetchLendDetailHydration(slug, `/lend/markets/${id}`)
  const {
    snapshot,
    transactions,
    risk,
    content,
    riskParameters,
    interestRateModel,
    siloedMarket,
    contractAddresses,
    supplyBorrow,
  } = hydration ?? {}
  // Fail closed in live mode when Convex has no snapshot — matches borrow detail
  // so the page never silently renders the mock catalog next to an empty live list.
  if (shouldFailClosedInLive(mode, snapshot != null)) return null
  const detail = buildLendMarketDetail(
    market,
    snapshot
      ? {
          suppliedUsd: snapshot.suppliedUsd,
          borrowedUsd: snapshot.borrowedUsd,
          availableUsd: snapshot.availableUsd,
          utilizationPct: snapshot.utilizationPct,
          supplyApyPct: snapshot.supplyApyPct,
          borrowAprPct: snapshot.borrowAprPct,
        }
      : undefined,
  )

  const headline = resolveLendHeadlineRates({
    snapshotBacked: Boolean(snapshot),
    detailUtilizationPct: detail.utilizationPct,
    detailBorrowAprPct: detail.borrowAprPct,
    irmUtilizationPct: interestRateModel?.utilizationPct,
    irmBorrowAprPct: interestRateModel?.borrowAprPct,
  })

  const emptySupplyBorrow = {
    supplied: emptySeries(`${slug}:sb:supplied`, "Supplied"),
    borrowed: emptySeries(`${slug}:sb:borrowed`, "Borrowed"),
    utilization: emptySeries(`${slug}:sb:utilization`, "Utilization"),
  }

  // protocolParameters has no empty-state card (an IRM table with no rows reads as
  // broken), so keep the catalog rows when Convex has no IRM — but make the fallback
  // loud in live so the missing lendInterestRateModel seed gets fixed.
  if (mode === "live" && !interestRateModel) warnLiveFallback("lend", slug, "interestRateModel")

  const hydrated = applyDetailContentOverlay(
    {
      ...detail,
      quickStats: injectSiloedMarketQuickStats(
        injectBaselinePrice(detail.quickStats, market.asset.symbol),
        siloedMarket,
      ),
      // heroFeed set by the page from preloadLendHero.
      cashflow: { bars: [], rows: [], periodLabel: "" },
      supplyBorrow: shouldStripMockSeriesForLive()
        ? ((supplyBorrow as typeof detail.supplyBorrow | null) ?? emptySupplyBorrow)
        : ((supplyBorrow as typeof detail.supplyBorrow | null) ?? detail.supplyBorrow),
      // Fail closed in live: empty (not the catalog copy) when Convex has no rows.
      // The client overlays the wallet's own session transactions on top of this.
      transactions:
        preferLiveOrNull(mode, transactions as typeof detail.transactions | null, detail.transactions) ?? [],
      // Single-source Supply APY: the seeded/frozen risk metric is realigned to the live
      // headline value Key Statistics shows, so the page never renders two different rates.
      risk: alignRiskSupplyApyMetric(
        preferLiveOrNull(mode, risk as typeof detail.risk | null, detail.risk) ?? EMPTY_RISK_ASSESSMENT,
        detail.quickStats,
      ),
      utilizationPct: headline.utilizationPct,
      borrowAprPct: headline.borrowAprPct,
      protocolParameters: interestRateModel ? irmProtocolParameters(interestRateModel) : detail.protocolParameters,
    },
    content,
    { clearWhenMissing: mode === "live" },
  )

  return applyRiskParametersToAbout(
    injectLendContractAddressStats(
      {
        ...hydrated,
        hero: overlayHeroIdentity(hydrated.hero, siloedMarket),
      },
      contractAddresses ?? [],
    ),
    riskParameters,
  )
}

// Request-scoped memoization keeps the detail builder safe if the route is rendered
// more than once during the same RSC request.
export const getLendMarketDetailFromConvex = cache(getLendMarketDetailFromConvexUncached)

/** Merge page preloadQuery results onto lend detail (C03 — avoid double HTTP fetch). */
export function applyLendPreloadedOverlays(
  detail: LendMarketDetail,
  overlays: {
    quickStats?: ReadonlyArray<PreloadedQuickStatRow> | null
    cashflow?: LendMarketDetail["cashflow"] | null
    baselinePriceSymbol: string
  },
): LendMarketDetail {
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
