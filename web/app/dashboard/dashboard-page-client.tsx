"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import type { RewardsPromoTabId, RewardsQuest } from "@/app/lib/data/rewards/catalog"
import { placeholderQuestsByTab } from "@/app/lib/data/rewards/quests"
import { useAvanaSessions } from "@/app/lib/avana-session/avana-sessions-provider"
import { PortfolioStatCards } from "@/app/dashboard/portfolio-stat-cards"
import { PortfolioRewardsCards } from "@/app/dashboard/_rewards-components/rewards-balance-hero"
import { DashboardWalletTab } from "./dashboard-wallet-tab"
import { LearnSection } from "@/app/dashboard/_rewards-components/learn-section"
import { RecentActivity } from "@/app/dashboard/recent-activity"
import { mapSwapTransactionHistoryToActivityRows } from "@/app/dashboard/swap-activity"
import { mapTransactionHistoryToActivityRows } from "@/app/lib/borrow-system/read-model"
import { buildLendActivityHistory } from "@/app/lib/lend-system/read-model"
import { detailSectionStackClass, MobileDetailActionBar } from "@/app/components/detail-page-primitives"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { UnderlineTabStrip } from "@/app/components/tab-primitives"
import { RewardsPromoContent, RewardsQuestSection } from "@/app/dashboard/_rewards-components/quests-tab"
import { MerklRewardsSection } from "@/app/dashboard/_rewards-components/merkl-rewards-section"

type DashboardPromoTabId = Extract<RewardsPromoTabId, "getting-started" | "lend" | "borrow" | "referrals">
type DashboardAccountTabId = Extract<RewardsPromoTabId, "lend" | "borrow">
type DashboardTabId = "wallet" | DashboardAccountTabId | "rewards"

const DASHBOARD_TABS: readonly { id: DashboardTabId; label: string }[] = [
  { id: "wallet", label: "Wallet" },
  { id: "lend", label: "Lend" },
  { id: "borrow", label: "Borrow" },
  { id: "rewards", label: "Rewards" },
]

function resolveDashboardTab(tab: string | null): DashboardTabId {
  switch (tab) {
    case "wallet":
    case "lend":
    case "borrow":
    case "rewards":
      return tab
    case "referrals":
      return "rewards"
    // Former All Transactions tab / activity aliases → default wallet tab.
    // Activity now lives in the sidebar feed.
    case "transactions":
    case "activity":
    default:
      return "wallet"
  }
}

function DashboardRewardsTab({ questsByTab }: { questsByTab: Record<RewardsPromoTabId, RewardsQuest[]> }) {
  const sections: Array<{ id: DashboardPromoTabId; title: string }> = [
    { id: "getting-started", title: "Getting Started" },
    { id: "lend", title: "Lend Rewards" },
    { id: "borrow", title: "Borrow Rewards" },
    { id: "referrals", title: "Referral Rewards" },
  ]

  return (
    <div className={detailSectionStackClass}>
      {sections.map(({ id, title }) => {
        const quests = questsByTab[id] ?? []
        if (quests.length === 0) return null
        return <RewardsQuestSection key={id} title={title} quests={quests} onTaskAction={noTaskAction} />
      })}
      <MerklRewardsSection />
    </div>
  )
}

/** Quests are placeholders until a rewards source exists: their actions do nothing. */
const noTaskAction = async () => undefined

export function DashboardPageClient() {
  const router = useRouter()
  const searchParams = useSearchParams()
  const searchTab = searchParams.get("tab")
  const { t } = useTranslation()
  const avana = useAvanaSessions()
  const walletId = avana.walletId
  const [activeDashboardTab, setActiveDashboardTab] = useState<DashboardTabId>(() => resolveDashboardTab(searchTab))

  useEffect(() => {
    setActiveDashboardTab(resolveDashboardTab(searchTab))
  }, [searchTab])

  const questsByTab = useMemo(() => placeholderQuestsByTab(t("Coming soon")), [t])

  const handleDashboardTabChange = useCallback(
    (tab: DashboardTabId) => {
      setActiveDashboardTab(tab)
      // Keep scroll position when swapping portfolio tabs — default App Router
      // navigation resets to the top of the page.
      router.push(`/dashboard?tab=${tab}`, { scroll: false })
    },
    [router],
  )

  // No rewards source exists yet: nothing is earned or claimable.
  const combinedActivityRows = [
    ...mapTransactionHistoryToActivityRows(avana.borrow.transactionHistory, avana.borrow.state.markets),
    ...buildLendActivityHistory(avana.lend.walletId, avana.lend.transactionHistory, avana.lend.state),
    ...mapSwapTransactionHistoryToActivityRows(avana.swap.transactionHistory),
  ]
  const seenIds = new Set<string>()
  const allActivityRows = combinedActivityRows.filter((row) => {
    if (seenIds.has(row.id)) return false
    seenIds.add(row.id)
    return true
  })

  return (
    <>
      <div className={detailSectionStackClass}>
        <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
          <div className="min-w-0 pb-8 lg:col-span-2">
            <PortfolioStatCards activeTab={activeDashboardTab} />
          </div>

          <aside className="min-w-0 lg:col-start-2 lg:row-start-2 lg:pt-8">
            <PortfolioRewardsCards
              earnedAmount={0}
              claimableAmount={0}
              activeTab={activeDashboardTab}
              showQuickActions
            />
            {/* Desktop sidebar — Activity stays beside rewards. */}
            <section
              id="dashboard-activity"
              className="mt-10 hidden scroll-mt-24 border-t border-border pt-10 lg:block"
            >
              <h2 className="mb-5 text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                {t("Activity")}
              </h2>
              <RecentActivity rows={allActivityRows} walletId={walletId} />
            </section>
          </aside>

          <div className="min-w-0 lg:col-start-1 lg:row-start-2 lg:pt-8">
            <section>
              <div className="mb-6 mt-10 border-t border-border pt-10 md:mt-12 md:pt-12 lg:hidden">
                <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground">
                  {t("Dashboard Positions")}
                </h2>
              </div>
              <UnderlineTabStrip
                items={DASHBOARD_TABS.map((tab) => ({ id: tab.id, label: t(tab.label) }))}
                value={activeDashboardTab}
                onChange={handleDashboardTabChange}
                ariaLabel={t("Dashboard tabs")}
                className="mb-6"
                listClassName="w-max min-w-full gap-6 px-2 sm:gap-9 sm:px-0"
                tabClassName="text-[18px] font-medium tracking-[-0.01em] md:text-[18px]"
              />

              <div className="min-w-0">
                {activeDashboardTab === "wallet" ? (
                  <DashboardWalletTab walletId={walletId} />
                ) : activeDashboardTab === "rewards" ? (
                  <DashboardRewardsTab questsByTab={questsByTab} />
                ) : (
                  <RewardsPromoContent
                    activePromoTab={activeDashboardTab}
                    questsByTab={questsByTab}
                    onTaskAction={noTaskAction}
                    returnHref={`/dashboard?tab=${activeDashboardTab}`}
                    showRewards={false}
                  />
                )}
              </div>

              {/* Mobile — Activity sits above Learn Avana. */}
              <section className="mt-10 border-t border-border pt-10 md:mt-12 md:pt-12 lg:hidden">
                <h2 className="mb-5 text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground">
                  {t("Activity")}
                </h2>
                <RecentActivity rows={allActivityRows} walletId={walletId} />
              </section>

              <div className="mt-10 border-t border-border pt-10 pb-24 md:mt-12 md:pt-12 lg:pb-0">
                <LearnSection />
              </div>
            </section>
          </div>
        </div>
      </div>

      {activeDashboardTab === "rewards" ? (
        <MobileDetailActionBar>
            <button
              type="button"
              disabled
              className={primaryCtaClass({ size: "compact", disabled: true, className: "w-full" })}
            >
              {t("No rewards ready")}
            </button>
        </MobileDetailActionBar>
      ) : null}

    </>
  )
}
