"use client"

import * as React from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import { AboutNewsSection } from "@/app/borrow/_detail/ui"
import { FlatStatsGrid, QuickStatsGrid } from "@/app/borrow/_detail/pool-sections"
import { useAvanaIdentity } from "@/app/lib/avana-session/avana-sessions-provider"
import { mapMultiplySessionRows, mapMultiplyTxRow } from "@/app/lib/detail-page/transaction-history"
import { useMultiplySessionContext } from "@/app/lib/multiply-system/multiply-session-context"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  DeferredDetailContent,
  DeferredDetailPlaceholder,
  detailAnalyticsSectionClass,
  detailAnalyticsStackClass,
  DetailPageWidth,
  MobileDetailActionBar,
} from "@/app/components/detail-page-primitives"
import { MarketHero, MarketHeroIdentity, MarketSidebar } from "@/app/multiply/_detail"
import type { MultiplyMarketDetail } from "@/app/lib/multiply-detail"

const MultiplyAnalyticsStack = dynamic(
  () => import("./multiply-analytics-stack").then((mod) => mod.MultiplyAnalyticsStack),
  {
    ssr: false,
    loading: () => <DeferredDetailPlaceholder />,
  },
)

type Props = {
  detail: MultiplyMarketDetail
}

const RiskSection = dynamic(
  () => import("@/app/borrow/_detail/pool-sections/RiskSection").then((mod) => mod.RiskSection),
  { ssr: false },
)
export function MarketDetailClient({ detail }: Props) {
  const session = useMultiplySessionContext()
  const { walletAddress } = useAvanaIdentity()
  const { t } = useTranslation()
  const marketId = detail.id.toLowerCase().replaceAll("_", "-")

  const sessionRows = React.useMemo(
    () =>
      mapMultiplySessionRows(
        session.transactionHistory,
        marketId,
        detail.row.protocol,
        detail.row.asset,
        walletAddress,
      ),
    [detail.row.asset, detail.row.protocol, marketId, session.transactionHistory, walletAddress],
  )
  const seedRows = React.useMemo(() => detail.transactions.map(mapMultiplyTxRow), [detail.transactions])

  return (
    <div className="bg-background">
      <main className="pb-24 pt-12 md:pb-12 md:pt-14">
        <div className="container mx-auto px-4">
          <DetailPageWidth>
            <nav
              aria-label={t("Breadcrumb")}
              className="mb-4 flex items-center gap-1.5 text-[15px] text-muted-foreground md:text-[16px]"
            >
              <Link href="/multiply" className="transition-colors hover:text-foreground">
                {t("Multiply")}
              </Link>
              <span aria-hidden className="font-normal text-muted-foreground">
                ›
              </span>
              <span className="font-normal text-foreground">{detail.hero.name}</span>
            </nav>

            <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
              <div className="min-w-0 border-b border-border pb-5 lg:col-span-2">
                <MarketHeroIdentity detail={detail} className="pb-0" />
              </div>

              <div className="min-w-0 lg:col-start-1 lg:row-start-2">
                <MarketHero detail={detail} hideIdentity className="mb-12" />

                <AboutNewsSection
                  about={detail.about}
                  aboutTitle={t("About {name}").replace("{name}", detail.hero.name)}
                  compactAboutTitle
                  newsImageUrl={detail.hero.visuals[0]?.iconUrl ?? detail.hero.visuals[1]?.iconUrl ?? undefined}
                  newsImageLabel={detail.hero.name}
                  mediaVariant="icon"
                  afterAbout={
                    <>
                      <section aria-label={t("Key Statistics")} className="space-y-6">
                        <h2 className="text-[22px] font-normal leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                          Key Statistics
                        </h2>
                        <QuickStatsGrid
                          detail={detail}
                          product="multiply"
                          columns={4}
                          priceSymbol={detail.hero.visuals[0].symbol}
                        />
                      </section>
                      <section aria-label={t("Market Rates")} className="space-y-6">
                        <h2 className="text-[22px] font-normal leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                          Market Rates
                        </h2>
                        <FlatStatsGrid stats={detail.marketRates} />
                      </section>
                      <RiskSection detail={detail} />
                    </>
                  }
                  className="pt-0"
                />

                <section aria-label={t("Multiply market analytics")} className={detailAnalyticsSectionClass}>
                  <DeferredDetailContent className={detailAnalyticsStackClass}>
                    <MultiplyAnalyticsStack
                      detail={detail}
                      seedRows={seedRows}
                      sessionRows={sessionRows}
                      marketId={marketId}
                    />
                  </DeferredDetailContent>
                </section>
              </div>

              <aside className="hidden lg:col-start-2 lg:row-start-2 lg:block lg:self-start">
                <MarketSidebar detail={detail} />
              </aside>
            </div>
          </DetailPageWidth>
        </div>
      </main>

      <MobileDetailActionBar className="grid grid-cols-2 gap-3">
        <Link
          href={actionPagePath("multiply", "multiply", { market: marketId, return: `/multiply/markets/${marketId}` })}
          className={primaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Multiply" />
          {t("Multiply")}
        </Link>
        <Link
          href={actionPagePath("multiply", "deleverage", { market: marketId, return: `/multiply/markets/${marketId}` })}
          className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Deleverage" />
          {t("Deleverage")}
        </Link>
      </MobileDetailActionBar>
    </div>
  )
}
