import "server-only"
import { requestCache as cache } from "@/app/lib/detail-page/request-cache"
import { fetchLendDetailHydration } from "@/app/lib/lend-system/market-hydration-server"
import type { PreloadedQuickStatRow } from "@/app/lib/detail-page/apply-preloaded-overlays"
import {
  applyDetailContentOverlay,
  injectBaselinePrice,
  mergeAliasedQuickStats,
} from "@/app/lib/detail-page/live-detail-helpers"
import { QUICK_STAT_ALIASES } from "@/app/lib/detail-page/live-quick-stats"
import { injectSiloedMarketQuickStats, overlayHeroIdentity } from "@/app/lib/detail-page/siloed-market-overlay"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import {
  aboutContractAddressLabelForSalt,
  isAboutContractAddressStat,
  sortAboutContractAddressRows,
} from "@/app/lib/detail-page/about-contract-addresses"
import { resolveLendHeadlineRates } from "./headline-rates"
import type { ProtocolParameterRow } from "@/app/lib/borrow-detail/protocol-parameters"
import { alignRiskSupplyApyMetric, buildLendMarketDetail } from "./detail-base"
import { lendMarketFromSnapshot } from "@/app/lib/lend-system/market-hydration"
import type { LendMarketDetail } from "./types"
import type { QuickStat } from "@/app/lib/borrow-detail"
import { formatPercent } from "@/app/lib/format"

/**
 * Server-only lend detail builder. The lend detail page calls this so its numbers come from
 * services/convex and match the list/hero:
 *   - the page is resolved from its services/convex snapshot row (no row -> 404)
 *   - reference values (supplied / borrowed / utilization / APY) <- snapshot
 *   - HERO chart (total supplied) <- daily series, preloaded on the page
 *   - risk / about / faqs / transactions / IRM <- services/convex queries
 *   - "Price" quick stat <- live price snapshot
 * A section services/convex does not serve renders its empty state. Kept OUT of `./index.ts`
 * because that barrel is also imported by client components.
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

/** Replace About contract-address rows with the services/convex rows (manifest addresses). */
function injectLendContractAddressStats(
  detail: LendMarketDetail,
  rows: ReadonlyArray<{ salt: string; label: string; href: string }>,
): LendMarketDetail {
  const contractRows = sortAboutContractAddressRows(rows.filter((row) => Boolean(row.href || row.label)))
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
  const slug = id
  // Supply hero / quick-stats / cashflow preloaded on the page - not fetched here.
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
  // The page exists only for a Hub asset services/convex reports.
  if (!snapshot) return null
  const market = lendMarketFromSnapshot({ ...snapshot, scope: "lend" }, 1, Date.now())
  const detail = buildLendMarketDetail(market, {
    suppliedUsd: snapshot.suppliedUsd,
    borrowedUsd: snapshot.borrowedUsd,
    availableUsd: snapshot.availableUsd,
    utilizationPct: snapshot.utilizationPct,
    supplyApyPct: snapshot.supplyApyPct,
    borrowAprPct: snapshot.borrowAprPct,
  })

  const headline = resolveLendHeadlineRates({
    snapshotBacked: true,
    detailUtilizationPct: detail.utilizationPct,
    detailBorrowAprPct: detail.borrowAprPct,
    irmUtilizationPct: interestRateModel?.utilizationPct,
    irmBorrowAprPct: interestRateModel?.borrowAprPct,
  })

  const hydrated = applyDetailContentOverlay(
    {
      ...detail,
      quickStats: injectSiloedMarketQuickStats(
        injectBaselinePrice(detail.quickStats, market.asset.symbol),
        siloedMarket,
      ),
      // heroFeed set by the page from preloadLendHero.
      cashflow: { bars: [], rows: [], periodLabel: "" },
      supplyBorrow: (supplyBorrow as typeof detail.supplyBorrow | null) ?? detail.supplyBorrow,
      // The client overlays the wallet's own session transactions on top of this.
      transactions: (transactions as typeof detail.transactions | null) ?? [],
      // Single-source Supply APY: the risk metric is realigned to the headline value Key
      // Statistics shows, so the page never renders two different rates.
      risk: alignRiskSupplyApyMetric((risk as typeof detail.risk | null) ?? EMPTY_RISK_ASSESSMENT, detail.quickStats),
      utilizationPct: headline.utilizationPct,
      borrowAprPct: headline.borrowAprPct,
      // Without the services/convex rate curve the IRM card shows its empty state.
      protocolParameters: interestRateModel ? irmProtocolParameters(interestRateModel) : [],
    },
    content,
    { clearWhenMissing: true },
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
