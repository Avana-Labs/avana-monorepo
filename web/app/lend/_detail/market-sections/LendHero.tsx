"use client"

import * as React from "react"
import { Globe, MessageSquare } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import type { LendMarketDetail } from "@/app/lib/lend-detail"
import { MarketHeroChart } from "@/app/components/charts/market-hero-chart"
import {
  formatChartPointLabel,
  formatChartValue,
  type ChartFeed,
  type ChartRangeData,
  type ChartValueFormat,
} from "@/app/components/charts"
import { getLendMarketHeroFeed } from "@/app/lib/chart-feeds"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { HeroContractLine } from "@/app/components/hero-contract-line"
import {
  isPlaceholderHeroContractAddress,
  contractExplorerHref,
  isSafeHeroLink,
  resolveHeroContractAddress,
} from "@/app/borrow/_detail/lib/hero-chart-feeds"
import { useLendSessionContext } from "@/app/lib/lend-system/lend-session-context"
import { buildWalletPositionFeed } from "@/app/lib/chart-feeds/wallet-position-feed"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type LendHeroProps = {
  detail: LendMarketDetail
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
  hideIdentity?: boolean
}

export function LendHeroIdentity({
  detail,
  leading,
  actions,
  className,
}: {
  detail: LendMarketDetail
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
  const websiteHref = isSafeHeroLink(detail.hero.explorerUrl)
    ? detail.hero.explorerUrl
    : `https://www.google.com/search?q=${encodeURIComponent(detail.hero.name)}`

  return (
    <header className={cn("pb-5", className)}>
      <div className="flex items-center justify-between gap-6">
        <div className="flex min-w-0 items-center gap-4">
          <div className="relative shrink-0">
            {leading}
            <TokenAvatar visual={detail.hero.visual} />
          </div>

          <div className="min-w-0">
            <div className="flex min-w-0 translate-y-1 items-baseline gap-3 whitespace-nowrap">
              <h1 className="min-w-0 truncate text-[26px] font-normal leading-8 tracking-[-0.015em] text-foreground sm:text-[28px]">
                {detail.hero.name}
              </h1>
              <span className="shrink-0 text-[20px] font-medium leading-none tracking-[-0.01em] text-foreground/55">
                {detail.hero.symbol}
              </span>
            </div>
            <HeroContractLine
              contextLabel="Asset on"
              chainLabel={detail.hero.chain}
              address={resolveHeroContractAddress(detail.id, detail.hero.explorerUrl)}
              isPlaceholder={isPlaceholderContract}
              explorerHref={contractExplorerHref(detail.hero.explorerUrl)}
            />
          </div>
        </div>

        <div className="hidden shrink-0 items-center gap-2 self-center pl-5 lg:flex">
          <HeroIcon label={t("Website")} onClick={() => window.open(websiteHref, "_blank")}>
            <Globe className="h-[18px] w-[18px]" />
          </HeroIcon>
          <HeroIcon
            label={t("X")}
            onClick={() => window.open(`https://x.com/search?q=${encodeURIComponent(detail.hero.symbol)}`, "_blank")}
          >
            <XIcon />
          </HeroIcon>
          <HeroIcon label={t("Share")} onClick={() => navigator.clipboard.writeText(window.location.href)}>
            <MessageSquare className="h-[18px] w-[18px]" />
          </HeroIcon>
          {actions}
        </div>
      </div>
    </header>
  )
}

export function LendHero(props: LendHeroProps) {
  // Match the Lend index strategy: preserve the server-provided market snapshot
  // through hydration rather than swapping in a second client-built value set.
  return <LendHeroView {...props} />
}

function LendHeroView({ detail, leading, actions, className, hideIdentity = false }: LendHeroProps) {
  const { t } = useTranslation()
  const session = useLendSessionContext()
  const metricTabs = React.useMemo(() => [t("Supplied"), t("Borrowed"), t("Utilization"), t("Your position")], [t])
  const [activeMetricTab, setActiveMetricTab] = React.useState(metricTabs[0])
  React.useEffect(() => {
    setActiveMetricTab(metricTabs[0])
  }, [metricTabs])
  const feed = React.useMemo(() => {
    const suppliedFeed = detail.heroFeed ?? getLendMarketHeroFeed(detail.id)
    if (activeMetricTab === metricTabs[3]) {
      const currentValueUsd = Object.values(session.state.positions)
        .filter((position) => position.marketId === detail.id && position.status === "active")
        .reduce((sum, position) => sum + position.suppliedValueUsd, 0)
      return buildWalletPositionFeed(
        currentValueUsd,
        session.transactionHistory
          .filter((item) => item.marketId === detail.id && item.status === "success" && item.kind !== "claim")
          .map((item) => ({
            timestamp: item.timestamp,
            deltaUsd: item.kind === "deposit" ? item.amount : -item.amount,
          })),
      )
    }
    if (activeMetricTab === metricTabs[1]) {
      return buildLendMetricFeed(detail.supplyBorrow.borrowed, "usdCompact", suppliedFeed)
    }
    if (activeMetricTab === metricTabs[2]) {
      return buildLendMetricFeed(detail.supplyBorrow.utilization, "percent", suppliedFeed, {
        headlineValue: `${(detail.supplyBorrow.utilization.aggregate ?? latestValue(detail.supplyBorrow.utilization.points) ?? 0).toFixed(2)}%`,
        valueFormat: "percent",
      })
    }
    return suppliedFeed
  }, [
    activeMetricTab,
    detail.heroFeed,
    detail.id,
    detail.supplyBorrow.borrowed,
    detail.supplyBorrow.utilization,
    metricTabs,
    session.state.positions,
    session.transactionHistory,
  ])

  return (
    <section className={cn("flex flex-col gap-5", className)} data-testid="lend-hero">
      {hideIdentity ? null : <LendHeroIdentity detail={detail} leading={leading} actions={actions} />}

      <div className="pt-4" data-testid="lend-hero-chart-card">
        <MarketHeroChart
          feed={feed}
          defaultRange="1M"
          hideIntradayRange
          gradientId={`lendHeroFill-${detail.id}`}
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

function buildLendMetricFeed(
  series: LendMarketDetail["supplyBorrow"]["supplied"],
  valueFormat: ChartValueFormat,
  fallback: ChartFeed,
  overrides?: Partial<Pick<ChartFeed, "headlineValue" | "valueFormat">>,
): ChartFeed {
  const points = series.points.map((point) => ({
    time: Date.parse(point.t),
    value: point.v,
    label: formatChartPointLabel(point.t),
  }))
  const latest = series.aggregate ?? points[points.length - 1]?.value ?? 0
  const first = points[0]?.value ?? latest
  const pct = first ? ((latest - first) / first) * 100 : 0
  const rangeData = makeRangeData(points.length ? points : fallback.rangeData["1D"])
  return {
    headlineValue: overrides?.headlineValue ?? formatChartValue(valueFormat, latest),
    headlineDelta: `${Math.abs(pct).toFixed(2)}%`,
    deltaTone: pct < 0 ? "negative" : "positive",
    rangeData,
    valueFormat: overrides?.valueFormat ?? valueFormat,
  }
}

function makeRangeData(points: ChartFeed["rangeData"]["1D"]): ChartRangeData {
  return {
    "1D": points,
    "1W": points.slice(-7),
    "1M": points.slice(-30),
    "3M": points.slice(-90),
    "1Y": points.slice(-365),
    All: points,
  }
}

function latestValue(points: LendMarketDetail["supplyBorrow"]["supplied"]["points"]) {
  return points[points.length - 1]?.v
}

function TokenAvatar({ visual }: { visual: LendMarketDetail["hero"]["visual"] }) {
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
