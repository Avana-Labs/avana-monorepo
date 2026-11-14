"use client"

import * as React from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { secondaryCtaClass } from "@/app/components/action-page/action-cta"
import type { PoolDetail } from "@/app/lib/borrow-detail"
import { AboutNewsSection } from "@/app/borrow/_detail/ui"
import {
  withEngineLiquidationThreshold,
  withGovernanceParameterView,
} from "@/app/borrow/_detail/lib/governance-parameters"
import { PoolHero, PoolHeroIdentity, QuickStatsGrid } from "@/app/borrow/_detail/pool-sections"
import { PoolBorrowSidebar } from "@/app/borrow/_detail/sidebars"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useAvanaIdentity, useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { mapBorrowSessionRows, mapBorrowTxRow } from "@/app/lib/detail-page/transaction-history"
import {
  DeferredDetailContent,
  DeferredDetailPlaceholder,
  detailAnalyticsSectionClass,
  detailAnalyticsStackClass,
  DetailPageWidth,
  MobileDetailActionBar,
} from "@/app/components/detail-page-primitives"

const RiskSection = dynamic(
  () => import("@/app/borrow/_detail/pool-sections/RiskSection").then((mod) => mod.RiskSection),
  { ssr: false },
)
const PoolAnalyticsStack = dynamic(() => import("./pool-analytics-stack").then((mod) => mod.PoolAnalyticsStack), {
  ssr: false,
  loading: () => <DeferredDetailPlaceholder />,
})

type Props = {
  detail: PoolDetail
}

/**
 * Two-column detail page for a single LP collateral pool.
 *
 * Desktop: sections fill the left column; `PoolBorrowSidebar` (homepage
 * CompactBorrowCard reused) sticks on the right. Mobile: sections stack and
 * the sidebar collapses into a bottom sheet triggered by a fixed button.
 */
export function PoolDetailClient({ detail }: Props) {
  const { t } = useTranslation()
  const { walletAddress } = useAvanaIdentity()
  const session = useBorrowSessionContext()
  const about = withEngineLiquidationThreshold(withGovernanceParameterView(detail.about, detail.protocolParameters))
  const seedRows = React.useMemo(() => detail.transactions.map(mapBorrowTxRow), [detail.transactions])
  const sessionRows = React.useMemo(
    () => mapBorrowSessionRows(session.transactionHistory, detail.row.id, undefined, "pool", walletAddress),
    [detail.row.id, session.transactionHistory, walletAddress],
  )

  return (
    <div className="bg-background">
      <main className="pb-24 pt-12 md:pb-12 md:pt-14">
        <div className="container mx-auto px-4">
          <DetailPageWidth>
            <nav
              aria-label={t("Breadcrumb")}
              className="mb-4 flex items-center gap-1.5 text-[15px] text-muted-foreground md:text-[16px]"
            >
              <Link href="/borrow" className="transition-colors hover:text-foreground">
                {t("Borrow")}
              </Link>
              <span aria-hidden className="font-normal text-muted-foreground">
                ›
              </span>
              <span className="font-normal text-foreground">{detail.hero.name}</span>
            </nav>

            <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
              <div className="min-w-0 border-b border-border pb-5 lg:col-span-2">
                <PoolHeroIdentity detail={detail} className="pb-0" />
              </div>

              <div className="min-w-0 lg:col-start-1 lg:row-start-2">
                <PoolHero detail={detail} hideIdentity className="mb-12" />

                <AboutNewsSection
                  about={about}
                  aboutTitle={t("About {name}").replace("{name}", detail.hero.name)}
                  compactAboutTitle
                  newsImageUrl={detail.hero.visuals[0].iconUrl ?? detail.hero.visuals[1].iconUrl ?? undefined}
                  newsImageLabel={detail.hero.name}
                  mediaVariant="icon"
                  afterAbout={
                    <>
                      <section aria-label={t("Key Statistics")} className="space-y-6">
                        <h2 className="text-[22px] font-normal leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
                          Key Statistics
                        </h2>
                        <QuickStatsGrid
                          detail={detail}
                          product="borrow"
                          hideRisk
                          pricePair={[detail.row.visuals[0].symbol, detail.row.visuals[1].symbol]}
                        />
                      </section>
                      <RiskSection detail={detail} />
                    </>
                  }
                  className="pt-0"
                />

                <section aria-label={t("Pool analytics")} className={detailAnalyticsSectionClass}>
                  <DeferredDetailContent className={detailAnalyticsStackClass}>
                    <PoolAnalyticsStack detail={detail} seedRows={seedRows} sessionRows={sessionRows} />
                  </DeferredDetailContent>
                </section>
              </div>

              <aside className="hidden lg:col-start-2 lg:row-start-2 lg:block lg:self-start">
                <PoolBorrowSidebar detail={detail} />
              </aside>
            </div>
          </DetailPageWidth>
        </div>
      </main>

      <MobileDetailActionBar className="grid grid-cols-2 gap-3">
        <Link
          href={actionPagePath("borrow", "supply", { market: detail.id, return: `/borrow/markets/${detail.id}` })}
          className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Pledge" />
          {t("Pledge")}
        </Link>
        <Link
          href={actionPagePath("borrow", "claim", { market: detail.id, return: `/borrow/markets/${detail.id}` })}
          className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Claim" />
          {t("Claim")}
        </Link>
      </MobileDetailActionBar>
    </div>
  )
}
