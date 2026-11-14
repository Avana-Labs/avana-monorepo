"use client"

import { useMemo, useState } from "react"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { useAvanaIdentity, useLendSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useDashboardLendLive } from "@/app/dashboard/use-dashboard-lend-live"
import { buildLendBalanceMetrics, buildLendDashboardMetrics } from "@/app/dashboard/dashboard-tab-metrics"
import { DashboardLendPerformanceSection } from "@/app/dashboard/dashboard-metric-section"
import { DashboardInvestments } from "@/app/dashboard/dashboard-investments"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import type { PortfolioLendTabData } from "@/app/lib/data/providers/portfolio"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"
import { ProductAvailableCard } from "./account-sections-shared"

const EMPTY_LEND_TAB: PortfolioLendTabData = { investments: [], positions: [], strategyBuckets: [], history: [] }
const LEND_MARKET_IDS = new Set(LEND_MARKET_CATALOG.map((market) => market.marketId))

/**
 * The lend account overview (performance metrics + supplied-asset table) that used
 * to live on the dashboard. Self-contained: it reads the live lend session directly
 * so it can be dropped onto the rewards Lend tab with no prop wiring.
 */
export function LendAccountSection({ returnHref = "/dashboard" }: { returnHref?: string }) {
  const { t } = useTranslation()
  const { walletId } = useAvanaIdentity()
  const lendSession = useLendSessionContext()
  const priceFor = useCanonicalPriceFor()
  const dashboardLend = useDashboardLendLive(walletId, lendSession)
  // Value every supplied position at the live oracle price so the Deposited column,
  // "Total Supplied", Net APY weighting and interest accrual all agree to the cent
  // (financial app — the sum of the table MUST equal the headline). Unpriced tokens
  // keep their stored supplied value.
  const lendTabData = useMemo<PortfolioLendTabData>(() => {
    const base = dashboardLend ?? EMPTY_LEND_TAB
    return {
      ...base,
      investments: base.investments.map((inv) => {
        const price = priceFor(inv.symbol)
        return price !== undefined ? { ...inv, suppliedUsd: inv.balance * price } : inv
      }),
    }
  }, [dashboardLend, priceFor])
  const balanceMetrics = buildLendBalanceMetrics(lendTabData)
  // Rewards/claimable stay on the assets Claim path — not on Lend Balance cards.
  const claimMetrics = buildLendDashboardMetrics(lendTabData)
  const [isClaiming, setIsClaiming] = useState(false)

  const handleClaimRewards = async () => {
    if (isClaiming) return
    setIsClaiming(true)
    try {
      await lendSession.claimRewards()
    } finally {
      setIsClaiming(false)
    }
  }

  return (
    <section id="dashboard-lend-account" className={`scroll-mt-24 ${detailSectionStackClass}`}>
      <DashboardLendPerformanceSection title={t("Lend Balance")} metrics={balanceMetrics} />
      <DashboardInvestments
        investments={lendTabData.investments}
        rewardsSummary={
          lendTabData.rewardsSummary ?? {
            claimableUsd: claimMetrics.claimableRewardsUsd,
            totalEarnedUsd: claimMetrics.interestEarnedUsd + claimMetrics.rewardsEarnedUsd,
          }
        }
        onClaimRewards={handleClaimRewards}
        isClaimingRewards={isClaiming}
        showHeading
        title={t("My Deposits")}
        countLabel={t("{count} assets").replace("{count}", String(lendTabData.investments.length))}
        returnHref={returnHref}
        accrualSinceMs={balanceMetrics.accrualSinceMs}
      />
      <ProductAvailableCard
        walletId={walletId ?? ""}
        sourceTypes={["wallet", "lend_available"]}
        allowedAssetIds={LEND_MARKET_IDS}
        title={t("Available to deposit")}
        action={{
          icon: "deposit",
          label: t("Deposit"),
          href: (row) => actionPagePath("lend", "deposit", { market: row.symbol.toLowerCase(), return: returnHref }),
        }}
      />
    </section>
  )
}
