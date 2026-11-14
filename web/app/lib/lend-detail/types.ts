/**
 * Public view-model for the lend (single-asset supply) detail page.
 *
 * Mirrors the multiply detail model: a lean per-market shape that reuses the
 * shared borrow-detail primitives (`Series`, `QuickStat`, `RiskAssessment`,
 * `EngagementTrend`, `AboutCard`, `CashflowCard`, `FaqContent`) and the shared
 * section components. The mock layer (`./mock.ts`) is the deterministic fallback;
 * the Convex layer (`./convex-detail.ts`) overlays seeded/live data per section,
 * falling back to the mock when Convex is unreachable.
 *
 * Convex fan-out (see `convex/*.ts`):
 *   hero / heroFeed / quickStats / supplyBorrow ← markets + marketDailyStats
 *   cashflow                                    ← lendRevenueDaily (lend.cashflow.getBreakdownForLend)
 *   engagement                                  ← walletEvents (getForLend)
 *   risk                                        ← lendRiskAssessments (lend.riskAssessment.getRisk)
 *   about / faqs                                ← lendMarketContent (lend.content.getContent)
 *   transactions                                ← sandbox txs / walletEvents (getRecentTransactions scope:"lend")
 */

import type { ChartFeed } from "@/app/components/charts"
import type { LendMarket } from "@/app/lib/lend-system/model/types"
import type { AboutCard, CashflowCard, QuickStat, RiskAssessment, Series, TxHistoryRow } from "@/app/lib/borrow-detail"
import type { FaqContent } from "@/app/lib/borrow-detail/content-model"
import type { ProtocolParameterRow } from "@/app/lib/borrow-detail/protocol-parameters"

/** Single-asset visual for the lend hero / related cards. */
export type LendTokenVisual = {
  symbol: string
  shortLabel: string
  bgClass: string
  textClass: string
  iconUrl?: string
}

export type LendMarketHero = {
  visual: LendTokenVisual
  name: string
  symbol: string
  subtitle: string
  chain: string
  category: "stable" | "crypto"
  /** Short venue label, e.g. "Avana Lend". */
  venue: string
  /** Link to the source contract / external explorer. */
  explorerUrl?: string
}

export type LendMarketDetail = {
  id: string
  hero: LendMarketHero
  /** Convex-backed hero chart feed (total supplied). Set only by the Convex detail
   * builder; the hero falls back to the local feed when absent. */
  heroFeed?: ChartFeed
  quickStats: QuickStat[]
  /** Current utilization % used by the interest-rate model chart. */
  utilizationPct: number
  /** Current borrow APR % used to anchor the interest-rate curve. */
  borrowAprPct: number
  /** Interest-rate model parameter rows (optimal util, slopes, base rate). */
  protocolParameters: ProtocolParameterRow[]
  supplyBorrow: {
    supplied: Series
    borrowed: Series
    utilization: Series
  }
  cashflow: CashflowCard
  risk: RiskAssessment
  about: AboutCard
  /** General FAQs (plain-text answers). */
  faqs: FaqContent[]
  transactions: TxHistoryRow[]
  /** Passthrough reference so the sidebar / actions can stay in sync. */
  row: LendMarket
}
