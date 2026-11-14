"use client"

import { lazy, useMemo } from "react"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { useAvanaIdentity, useMultiplySessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useDashboardMultiplyLive } from "@/app/dashboard/use-dashboard-multiply-live"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import {
  buildMultiplyBalanceMetrics,
  buildMultiplyPositionLiveApyByMarket,
  type MultiplyBalanceMetrics,
} from "@/app/dashboard/dashboard-tab-metrics"
import { DashboardMultiplyBalanceSection } from "@/app/dashboard/dashboard-metric-section"
import { SuppliesHealthFactorCard } from "@/app/dashboard/borrow-tab/supplies-table"
import { CurrentLtvCard } from "@/app/dashboard/borrow-tab/debts-table"
import type { BorrowSnapshot } from "@/app/dashboard/borrow-hero-state"
import type { PortfolioMultiplyTabData } from "@/app/lib/data/providers/portfolio"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { useHasMounted } from "@/app/lib/ui/use-has-mounted"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { HealthRiskBanner } from "@/app/dashboard/health-risk-banner"
import { AccountModuleBoundary, MultiplyAvailableMarketsCard } from "./account-sections-shared"

const MultiplyCollateralTable = lazy(async () => ({
  default: (await import("@/app/dashboard/multiply-collateral-table")).MultiplyCollateralTable,
}))

const EMPTY_MULTIPLY_TAB: PortfolioMultiplyTabData = {
  creditLines: {
    approvedUsd: 0,
    liquidationThresholdUsd: 0,
    averageHealthFactor: null,
    currentLtvPct: 0,
    totalBorrowedUsd: 0,
    totalCollateralUsd: 0,
  },
  lpCollaterals: [],
  positions: [],
  openOrders: [],
  twapOrders: [],
  history: [],
}

/**
 * The multiply account overview + positions that used to live on the dashboard.
 * Self-contained: reads the live multiply session directly, no props.
 * Empty wallets stay empty — no preview fixtures.
 */
export function MultiplyAccountSection({ returnHref = "/dashboard" }: { returnHref?: string }) {
  const { t } = useTranslation()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const hasMounted = useHasMounted()
  const { walletId } = useAvanaIdentity()
  const multiplySession = useMultiplySessionContext()

  const collateralPriceFor = useCanonicalPriceFor()
  const portfolioMultiply = useDashboardMultiplyLive(walletId, multiplySession, collateralPriceFor)

  const multiplyTabData = useMemo(
    () => (hasMounted ? (portfolioMultiply ?? EMPTY_MULTIPLY_TAB) : EMPTY_MULTIPLY_TAB),
    [hasMounted, portfolioMultiply],
  )

  const multiplySnapshot = useMemo<BorrowSnapshot>(() => {
    const credit = multiplyTabData.creditLines
    return {
      approvedUsd: credit?.approvedUsd ?? 0,
      liquidationThresholdUsd: credit?.liquidationThresholdUsd ?? 0,
      totalBorrowedUsd: credit?.totalBorrowedUsd ?? 0,
      totalCollateralUsd: credit?.totalCollateralUsd ?? 0,
      averageHealthFactor: credit?.averageHealthFactor ?? null,
      currentLtvPct: credit?.currentLtvPct ?? 0,
    }
  }, [multiplyTabData.creditLines])

  const multiplyBalanceMetrics = useMemo<MultiplyBalanceMetrics>(
    () => buildMultiplyBalanceMetrics(multiplySession.state, walletId ?? "", multiplyTabData),
    [multiplySession.state, multiplyTabData, walletId],
  )

  const netApyByMarket = useMemo(
    () => buildMultiplyPositionLiveApyByMarket(multiplySession.state, walletId ?? ""),
    [multiplySession.state, walletId],
  )

  return (
    <section id="dashboard-multiply-account" className={`scroll-mt-24 ${detailSectionStackClass}`}>
      <DashboardMultiplyBalanceSection title={t("Multiply Balance")} metrics={multiplyBalanceMetrics} />
      <div className="space-y-4">
        <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">
          {t("Multiply Health")}
        </h3>
        <HealthRiskBanner healthFactor={multiplySnapshot.averageHealthFactor} product="multiply" />
        <div className="grid gap-4 xl:grid-cols-2">
          <SuppliesHealthFactorCard
            averageHealthFactor={multiplySnapshot.averageHealthFactor}
            showBalance={showDollarAmounts}
            title={t("Lowest Position Health")}
            helpText={t(
              "The health factor of your closest-to-liquidation Multiply position — the lowest across your open loops, not the portfolio blend. Below 1.0 triggers liquidation.",
            )}
          />
          <CurrentLtvCard
            borrowedUsd={multiplySnapshot.totalBorrowedUsd}
            collateralUsd={multiplySnapshot.totalCollateralUsd}
            showBalance={showDollarAmounts}
          />
        </div>
      </div>
      <AccountModuleBoundary product="multiply">
        <MultiplyCollateralTable
          rows={multiplyTabData.lpCollaterals}
          netApyByMarket={netApyByMarket}
          returnHref={returnHref}
        />
      </AccountModuleBoundary>
      <MultiplyAvailableMarketsCard
        walletId={walletId ?? ""}
        markets={multiplySession.state.markets}
        title={t("Available to loop")}
      />
    </section>
  )
}
