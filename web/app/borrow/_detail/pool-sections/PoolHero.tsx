"use client"

import * as React from "react"
import { Globe, MessageSquare } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import type { PoolDetail } from "@/app/lib/borrow-detail"
import { MarketHeroChart } from "@/app/components/charts/market-hero-chart"
import { getPoolHeroFeed } from "@/app/lib/chart-feeds"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { HeroContractLine } from "@/app/components/hero-contract-line"
import {
  buildFeedFromRangeSeries,
  isPlaceholderHeroContractAddress,
  contractExplorerHref,
  isSafeHeroLink,
  resolveHeroContractAddress,
} from "@/app/borrow/_detail/lib/hero-chart-feeds"
import { useAvanaIdentity, useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useDashboardBorrowLive } from "@/app/dashboard/use-dashboard-borrow-live"
import { currentCollateralValueUsd6 } from "@/app/lib/borrow-system/model"
import { buildWalletPositionFeed } from "@/app/lib/chart-feeds/wallet-position-feed"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type PoolHeroProps = {
  detail: PoolDetail
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
  hideIdentity?: boolean
}

export function PoolHeroIdentity({
  detail,
  leading,
  actions,
  className,
}: {
  detail: PoolDetail
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
}) {
  const { t } = useTranslation()
  // Suppress copy + Etherscan when the address is a synthetic placeholder that
  // points at no real contract.
  const isPlaceholderContract = isPlaceholderHeroContractAddress(
    resolveHeroContractAddress(detail.id, detail.hero.explorerUrl),
  )
  const websiteHref = isSafeHeroLink(detail.hero.explorerUrl) ? detail.hero.explorerUrl : null

  return (
    <header className={cn("pb-5", className)}>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between sm:gap-6">
        <div className="flex min-w-0 items-center gap-4">
          <div className="relative shrink-0">
            {leading}
            <div className="flex -space-x-2.5">
              <TokenAvatar visual={detail.hero.visuals[0]} />
              <TokenAvatar visual={detail.hero.visuals[1]} />
            </div>
          </div>

          <div className="min-w-0">
            <div className="flex min-w-0 translate-y-1 items-baseline gap-2.5 whitespace-nowrap">
              <h1 className="min-w-0 truncate text-[26px] font-normal leading-8 tracking-[-0.015em] text-foreground sm:text-[28px]">
                {detail.hero.name}
              </h1>
            </div>
            <HeroContractLine
              contextLabel="Market on"
              address={resolveHeroContractAddress(detail.id, detail.hero.explorerUrl)}
              isPlaceholder={isPlaceholderContract}
              explorerHref={contractExplorerHref(detail.hero.explorerUrl)}
            />
          </div>
        </div>

        <div className="flex shrink-0 items-center gap-2 self-center sm:pl-5">
          <HeroIcon
            label={t("Website")}
            onClick={() => {
              if (!websiteHref) return
              window.open(websiteHref, "_blank")
            }}
          >
            <Globe className="h-[18px] w-[18px]" />
          </HeroIcon>
          <HeroIcon
            label={t("X")}
            onClick={() => {
              if (!detail.hero.xUrl) return
              window.open(detail.hero.xUrl, "_blank")
            }}
          >
            <XIcon />
          </HeroIcon>
          <HeroIcon label={t("Share")} onClick={() => navigator.clipboard.writeText(window.location.href)}>
            <MessageSquare className="h-3.5 w-3.5" />
          </HeroIcon>
          {actions}
        </div>
      </div>
    </header>
  )
}

export function PoolHero(props: PoolHeroProps) {
  // The route already merges its server-preloaded Convex series into `detail`.
  // Keep that first real snapshot through hydration instead of handing the chart
  // to a second client subscription whose initial result can replace the numbers.
  return <PoolHeroView {...props} />
}

function PoolHeroView({ detail, leading, actions, className, hideIdentity = false }: PoolHeroProps) {
  const { t } = useTranslation()
  const session = useBorrowSessionContext()
  const { walletId } = useAvanaIdentity()
  // Convex-backed portfolio (same adapter the dashboard uses) so "Your position"
  // reflects the onboarded + live collateral in this pool even when the in-memory
  // session hasn't hydrated those positions on this route. (D4)
  const portfolioBorrow = useDashboardBorrowLive(walletId, session)
  const metricTabs = React.useMemo(() => [t("Supplied"), t("Borrowed"), t("Utilization"), t("Your position")], [t])
  const [activeMetricTab, setActiveMetricTab] = React.useState(metricTabs[0])
  React.useEffect(() => {
    setActiveMetricTab(metricTabs[0])
  }, [metricTabs])
  // Prefer Convex-backed feeds for every hero tab. Borrowed/Utilization used to
  // read mock series seeded from spoke.liquidityUsd (~$1.25B), which disagreed
  // with Convex Supplied (~$63M) on the same page.
  const feed = React.useMemo(() => {
    if (activeMetricTab === metricTabs[3]) {
      const account = session.state.accounts[walletId]
      const sessionValueUsd = (account?.collateralPositions ?? [])
        .filter((position) => position.marketId === detail.id)
        .reduce((sum, position) => {
          const market = session.state.markets[position.marketId]
          return sum + (market ? Number(currentCollateralValueUsd6(position, market)) / 1_000_000 : 0)
        }, 0)
      const convexValueUsd = (portfolioBorrow?.collateralPositions ?? [])
        .filter((row) => row.pool.id === detail.id)
        .reduce((sum, row) => sum + row.pool.collateralUsd, 0)
      const currentValueUsd = convexValueUsd > 0 ? convexValueUsd : sessionValueUsd
      return buildWalletPositionFeed(
        currentValueUsd,
        session.transactionHistory
          .filter((item) => item.marketId === detail.id && item.status === "success")
          .filter((item) => item.kind === "deposit" || item.kind === "withdraw")
          .map((item) => ({
            timestamp: item.timestamp,
            deltaUsd: (item.kind === "deposit" ? 1 : -1) * (Number(item.executedAmountUsd6) / 1_000_000),
          })),
      )
    }
    if (activeMetricTab === metricTabs[1]) {
      return (
        detail.heroBorrowedFeed ??
        buildFeedFromRangeSeries(
          detail.heroMetric.series.borrowed,
          "usdCompact",
          detail.heroFeed ?? getPoolHeroFeed(detail.id),
        )
      )
    }
    if (activeMetricTab === metricTabs[2]) {
      return (
        detail.heroUtilizationFeed ??
        buildFeedFromRangeSeries(
          detail.heroMetric.series.utilization,
          "percent",
          detail.heroFeed ?? getPoolHeroFeed(detail.id),
        )
      )
    }
    return (
      detail.heroFeed ??
      buildFeedFromRangeSeries(detail.heroMetric.series.tvl, "usdCompact", getPoolHeroFeed(detail.id))
    )
  }, [
    activeMetricTab,
    detail.heroBorrowedFeed,
    detail.heroFeed,
    detail.heroMetric.series,
    detail.heroUtilizationFeed,
    detail.id,
    metricTabs,
    portfolioBorrow,
    session.state,
    session.transactionHistory,
    walletId,
  ])

  return (
    <section className={cn("flex flex-col gap-5", className)} data-testid="pool-hero">
      {hideIdentity ? null : <PoolHeroIdentity detail={detail} leading={leading} actions={actions} />}

      <div className="pt-4" data-testid="pool-hero-chart-card">
        <MarketHeroChart
          feed={feed}
          defaultRange="1M"
          hideIntradayRange
          gradientId={`poolHeroFill-${detail.id}`}
          height={310}
          showMeta={false}
          metricTabs={metricTabs}
          activeMetricTab={activeMetricTab}
          onMetricTabChange={setActiveMetricTab}
          balanceVariant="strong"
          balanceClassName="absolute left-0 top-0 z-10 -translate-y-0.5"
        />
      </div>
    </section>
  )
}

function TokenAvatar({ visual }: { visual: PoolDetail["hero"]["visuals"][number] }) {
  return (
    <span
      role="img"
      className={cn("inline-flex size-16 items-center justify-center", visual.textClass)}
      aria-label={visual.symbol}
    >
      {visual.iconUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={sizedLocalIconSrc(visual.iconUrl, 64)}
          alt=""
          className="size-16 object-contain"
          width={64}
          height={64}
          fetchPriority="high"
        />
      ) : (
        <span className="text-[12px] font-medium">{visual.shortLabel}</span>
      )}
    </span>
  )
}

function HeroIcon({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className="flex size-10 items-center justify-center rounded-full text-foreground/75 transition-colors hover:bg-hover hover:text-foreground md:size-9"
    >
      {children}
    </button>
  )
}

function XIcon() {
  return (
    <svg className="h-[18px] w-[18px] fill-current" viewBox="0 0 28 28" aria-hidden="true">
      <path d="M16.093 12.7389L24.283 3H22.3422L15.2308 11.4562L9.55101 3H3L11.589 15.7872L3 26H4.94088L12.4507 17.07L18.449 26H25L16.0925 12.7389H16.093ZM13.4347 15.8999L12.5644 14.6266L5.6402 4.49462H8.62127L14.2092 12.6714L15.0795 13.9448L22.3431 24.5733H19.3621L13.4347 15.9004V15.8999Z" />
    </svg>
  )
}
