"use client"

import * as React from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import type { AssetDetail } from "@/app/lib/borrow-detail"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import {
  DeferredDetailContent,
  DeferredDetailPlaceholder,
  detailAnalyticsSectionClass,
  detailAnalyticsStackClass,
  DetailPageWidth,
  MobileDetailActionBar,
} from "@/app/components/detail-page-primitives"
import { AssetHero, AssetHeroIdentity } from "@/app/borrow/_detail/asset-sections"
import { QuickStatsGrid } from "@/app/borrow/_detail/pool-sections"
import { withGovernanceParameterView } from "@/app/borrow/_detail/lib/governance-parameters"
import { AboutNewsSection } from "@/app/borrow/_detail/ui"
import { AssetTokenSidebar } from "@/app/borrow/_detail/sidebars"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useAvanaIdentity, useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { mapBorrowSessionRows, mapBorrowTxRow } from "@/app/lib/detail-page/transaction-history"
import { cn } from "@/lib/utils"

const RiskSection = dynamic(() => import("@/app/borrow/_detail/pool-sections").then((mod) => mod.RiskSection), {
  ssr: false,
  loading: () => <DeferredBlock className="h-[320px]" />,
})
const AssetAnalyticsStack = dynamic(() => import("./asset-analytics-stack").then((mod) => mod.AssetAnalyticsStack), {
  ssr: false,
  loading: () => <DeferredDetailPlaceholder />,
})

function DeferredBlock({ className }: { className?: string }) {
  return <div className={cn("rounded-radius-md border border-border bg-surface-raised/60", className)} />
}

type Props = {
  detail: AssetDetail
}

export function AssetDetailClient({ detail }: Props) {
  const { t } = useTranslation()
  const { walletAddress } = useAvanaIdentity()
  const session = useBorrowSessionContext()
  const closeHref = `/borrow/assets/${detail.row.id}`
  const about = withGovernanceParameterView(detail.about, detail.protocolParameters)
  const seedRows = React.useMemo(() => detail.transactions.map(mapBorrowTxRow), [detail.transactions])
  const sessionRows = React.useMemo(
    () => mapBorrowSessionRows(session.transactionHistory, detail.row.id, detail.hero.symbol, "asset", walletAddress),
    [detail.hero.symbol, detail.row.id, session.transactionHistory, walletAddress],
  )
  return (
    <div className="min-h-screen bg-background text-foreground">
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
                <AssetHeroIdentity detail={detail} className="pb-0" />
              </div>

              <div className="min-w-0 lg:col-start-1 lg:row-start-2">
                <AssetHero detail={detail} hideIdentity className="mb-12" />

                <AboutNewsSection
                  about={about}
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
                        <QuickStatsGrid detail={detail} product="borrow" hideRisk />
                      </section>
                      <RiskSection detail={detail} />
                    </>
                  }
                  className="pt-0"
                />

                <section aria-label={t("Asset analytics")} className={detailAnalyticsSectionClass}>
                  <DeferredDetailContent className={detailAnalyticsStackClass}>
                    <AssetAnalyticsStack detail={detail} seedRows={seedRows} sessionRows={sessionRows} />
                  </DeferredDetailContent>
                </section>
              </div>

              <aside className="hidden lg:col-start-2 lg:row-start-2 lg:block lg:self-start">
                <div className="sticky top-20">
                  <AssetTokenSidebar detail={detail} />
                </div>
              </aside>
            </div>
          </DetailPageWidth>
        </div>
      </main>

      <MobileDetailActionBar className="grid grid-cols-2 gap-3">
        <Link
          href={actionPagePath("borrow", "borrow", { asset: detail.row.id, return: closeHref })}
          className={primaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Borrow" />
          {t("Borrow")}
        </Link>
        <Link
          href={actionPagePath("borrow", "repay", { asset: detail.row.id, return: closeHref })}
          className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-normal [&_svg]:size-5" })}
        >
          <ActionIcon label="Repay" />
          {t("Repay")}
        </Link>
      </MobileDetailActionBar>
    </div>
  )
}
