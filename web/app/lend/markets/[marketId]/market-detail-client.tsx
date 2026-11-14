"use client"

import * as React from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import { AboutNewsSection } from "@/app/borrow/_detail/ui"
import { QuickStatsGrid } from "@/app/borrow/_detail/pool-sections"
import { LendHero, LendHeroIdentity, LendSidebar } from "@/app/lend/_detail"
import { useLendSessionContext } from "@/app/lib/lend-system/lend-session-context"
import { useAvanaIdentity } from "@/app/lib/avana-session/avana-sessions-provider"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { LendMarketDetail } from "@/app/lib/lend-detail"
import { mapBorrowTxRow, mapLendSessionRows } from "@/app/lib/detail-page/transaction-history"
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
const LendAnalyticsStack = dynamic(() => import("./lend-analytics-stack").then((mod) => mod.LendAnalyticsStack), {
  ssr: false,
  loading: () => <DeferredDetailPlaceholder />,
})

type Props = {
  detail: LendMarketDetail
}

/** Map a wallet's own sandbox lend actions into detail transaction rows. */
function mapSessionRows(
  history: ReturnType<typeof useLendSessionContext>["transactionHistory"],
  marketId: string,
  assetSymbol: string,
  priceUsd?: number,
  walletAddress?: string,
) {
  return mapLendSessionRows(history, marketId, assetSymbol, priceUsd, walletAddress)
}

export function LendMarketDetailClient({ detail }: Props) {
  const session = useLendSessionContext()
  const { walletAddress } = useAvanaIdentity()
  const { t } = useTranslation()
  const marketId = detail.row.marketId

  const priceUsd = React.useMemo(() => {
    const priceStat = detail.quickStats.find((stat) => stat.id === "price")
    if (!priceStat?.value) return undefined
    const parsed = Number(priceStat.value.replace(/[^0-9.]/g, ""))
    return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined
  }, [detail.quickStats])

  const sessionRows = React.useMemo(
    () => mapSessionRows(session.transactionHistory, marketId, detail.hero.symbol, priceUsd, walletAddress),
    [detail.hero.symbol, marketId, priceUsd, session.transactionHistory, walletAddress],
  )
  const seedRows = React.useMemo(() => detail.transactions.map(mapBorrowTxRow), [detail.transactions])

  return (
    <div className="bg-background">
      <main className="pb-24 pt-12 md:pb-12 md:pt-14">
        <div className="container mx-auto px-4">
          <DetailPageWidth>
            <nav
              aria-label={t("Breadcrumb")}
              className="mb-4 flex items-center gap-1.5 text-[15px] text-muted-foreground md:text-[16px]"
            >
              <Link href="/lend" className="transition-colors hover:text-foreground">
                {t("Lend")}
              </Link>
              <span aria-hidden className="font-normal text-muted-foreground">
                ›
              </span>
              <span className="font-normal text-foreground">{detail.hero.name}</span>
            </nav>

            <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
              <div className="min-w-0 border-b border-border pb-5 lg:col-span-2">
                <LendHeroIdentity detail={detail} className="pb-0" />
              </div>

              <div className="min-w-0 lg:col-start-1 lg:row-start-2">
                <LendHero detail={detail} hideIdentity className="mb-12" />

                <AboutNewsSection
                  about={detail.about}
                  aboutTitle={t("About {name}").replace("{name}", detail.hero.name)}
                  compactAboutTitle
                  newsImageUrl={detail.hero.visual.iconUrl ?? undefined}
                  newsImageLabel={detail.hero.symbol}
                  mediaVariant="icon"
                  afterAbout={
                    <>
                      <section aria-label={t("Key Statistics")} className="space-y-6">
                        <h2 className="text-[22px] font-normal leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                          Key Statistics
                        </h2>
                        <QuickStatsGrid detail={detail} product="lend" />
                      </section>
                      <RiskSection detail={detail} />
                    </>
                  }
                  className="pt-0"
                />

                <section aria-label={t("Lend market analytics")} className={detailAnalyticsSectionClass}>
                  <DeferredDetailContent className={detailAnalyticsStackClass}>
                    <LendAnalyticsStack
                      detail={detail}
                      seedRows={seedRows}
                      sessionRows={sessionRows}
                      marketId={marketId}
                    />
                  </DeferredDetailContent>
                </section>
              </div>

              <aside className="hidden lg:col-start-2 lg:row-start-2 lg:block lg:self-start">
                <LendSidebar detail={detail} />
              </aside>
            </div>
          </DetailPageWidth>
        </div>
      </main>

      <MobileDetailActionBar className="grid grid-cols-2 gap-3">
        <Link
          href={actionPagePath("lend", "deposit", { market: marketId, return: `/lend/markets/${marketId}` })}
          className={primaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Deposit" />
          {t("Deposit")}
        </Link>
        <Link
          href={actionPagePath("lend", "withdraw", { market: marketId, return: `/lend/markets/${marketId}` })}
          className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Withdraw" />
          {t("Withdraw")}
        </Link>
      </MobileDetailActionBar>
    </div>
  )
}
