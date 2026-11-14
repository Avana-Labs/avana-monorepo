"use client"

import * as React from "react"
import { Globe, MessageSquare } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import type { AssetDetail } from "@/app/lib/borrow-detail"
import { MarketHeroChart } from "@/app/components/charts/market-hero-chart"
import { getAssetHeroFeed } from "@/app/lib/chart-feeds"
import { useDashboardBorrowLive } from "@/app/dashboard/use-dashboard-borrow-live"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { HeroContractLine } from "@/app/components/hero-contract-line"
import {
  buildFeedFromRangeSeries,
  isPlaceholderHeroContractAddress,
  isSafeHeroLink,
  resolveHeroContractAddress,
} from "@/app/borrow/_detail/lib/hero-chart-feeds"
import { useAvanaIdentity, useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"
import { buildWalletPositionFeed } from "@/app/lib/chart-feeds/wallet-position-feed"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type Props = {
  detail: AssetDetail
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
  hideIdentity?: boolean
}

export function AssetHeroIdentity({
  detail,
  leading,
  actions,
  className,
}: {
  detail: AssetDetail
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
}) {
  const { t } = useTranslation()
  const providedContractAddress =
    detail.hero.contractAddress && /^0x[a-fA-F0-9]{40}$/i.test(detail.hero.contractAddress)
      ? detail.hero.contractAddress
      : null
  const contractAddress = providedContractAddress ?? resolveHeroContractAddress(detail.id)
  // A synthetic placeholder (or a purely id-derived fallback address) points at no
  // real contract — suppress the copy action and the Etherscan link for it.
  const isPlaceholderContract = !providedContractAddress || isPlaceholderHeroContractAddress(providedContractAddress)
  const websiteHref = isSafeHeroLink(detail.hero.websiteUrl)
    ? detail.hero.websiteUrl
    : isPlaceholderContract
      ? null
      : `https://etherscan.io/address/${contractAddress}`
  const showSymbol =
    detail.hero.symbol.trim().length > 0 &&
    detail.hero.symbol.trim().toLowerCase() !== detail.hero.name.trim().toLowerCase()

  return (
    <header className={cn("pb-5", className)}>
      <div className="flex items-center justify-between gap-6">
        <div className="flex min-w-0 items-center gap-4">
          <div className="relative shrink-0">
            {leading}
            <span
              role="img"
              aria-label={detail.hero.symbol}
              className={cn("inline-flex size-16 items-center justify-center", detail.hero.visual.textClass)}
            >
              {detail.hero.visual.iconUrl ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={sizedLocalIconSrc(detail.hero.visual.iconUrl, 64)}
                  alt=""
                  className="size-16 object-contain"
                  width={64}
                  height={64}
                  fetchPriority="high"
                />
              ) : (
                <span className="text-[13px] font-medium">{detail.hero.visual.shortLabel}</span>
              )}
            </span>
          </div>

          <div className="min-w-0">
            <div className="flex min-w-0 translate-y-1 items-baseline gap-2.5 whitespace-nowrap">
              <h1 className="min-w-0 truncate text-[26px] font-normal leading-8 tracking-[-0.015em] text-foreground sm:text-[28px]">
                {detail.hero.name}
              </h1>
              {showSymbol ? (
                <span className="shrink-0 text-[20px] font-medium leading-none tracking-[-0.01em] text-foreground/55">
                  {detail.hero.symbol}
                </span>
              ) : null}
            </div>
            <HeroContractLine
              contextLabel="Asset on"
              chainLabel={detail.hero.chain}
              address={contractAddress}
              isPlaceholder={isPlaceholderContract}
              explorerHref={`https://etherscan.io/address/${contractAddress}`}
            />
          </div>
        </div>

        <div className="hidden shrink-0 items-center gap-2 self-center pl-5 lg:flex">
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
            label="X"
            onClick={() =>
              window.open(
                detail.hero.xUrl ?? `https://x.com/search?q=${encodeURIComponent(detail.hero.symbol)}`,
                "_blank",
              )
            }
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

export function AssetHero(props: Props) {
  // `detail` already contains the server-preloaded Convex snapshot. Rendering it
  // directly prevents a second client-side series from replacing visible values.
  return <AssetHeroView {...props} />
}

function AssetHeroView({ detail, leading, actions, className, hideIdentity = false }: Props) {
  const { t } = useTranslation()
  const session = useBorrowSessionContext()
  const { walletId } = useAvanaIdentity()
  // The in-memory borrow session on a detail page doesn't carry the wallet's
  // onboarded debt positions (those live in Convex; the session hydrates them
  // inconsistently across routes). Read the authoritative Convex-backed portfolio
  // via the same read adapter the dashboard uses, so "Your position" reflects the
  // real onboarded + live debt in this asset instead of a flat $0. (D4)
  const portfolioBorrow = useDashboardBorrowLive(walletId, session)
  const metricTabs = React.useMemo(() => [t("Supplied"), t("Borrowed"), t("Utilization"), t("Your position")], [t])
  const [activeMetricTab, setActiveMetricTab] = React.useState(metricTabs[0])
  React.useEffect(() => {
    setActiveMetricTab(metricTabs[0])
  }, [metricTabs])
  // Prefer Convex-backed feeds for every hero tab (mirrors PoolHero). Borrowed/Utilization
  // used to read only the PRNG mock series; now they fall back to it only when Convex is
  // unseeded, so all three tabs agree with the live market size.
  const feed = React.useMemo(() => {
    const fallback = detail.heroFeed ?? getAssetHeroFeed(detail.id)
    if (activeMetricTab === metricTabs[3]) {
      // Current value from the Convex-backed portfolio (has the onboarded debt);
      // fall back to the in-memory session only if the adapter hasn't resolved yet.
      const symbol = detail.hero.symbol.toLowerCase()
      const convexValueUsd = (portfolioBorrow?.debtPositions ?? [])
        .filter((row) => row.debtAssetSymbol.toLowerCase() === symbol)
        .reduce((sum, row) => sum + row.borrowedUsd, 0)
      const sessionValueUsd = (session.state.accounts[walletId]?.debtPositions ?? [])
        .filter((position) => position.baseAssetId === detail.id || position.assetId.endsWith(`:${detail.id}`))
        .reduce((sum, position) => sum + Number(currentDebtValueUsd6(position)) / 1_000_000, 0)
      const currentValueUsd = convexValueUsd > 0 ? convexValueUsd : sessionValueUsd
      return buildWalletPositionFeed(
        currentValueUsd,
        session.transactionHistory
          .filter(
            (item) =>
              item.status === "success" &&
              (item.assetId === detail.id || item.assetId?.endsWith(`:${detail.id}`)) &&
              (item.kind === "borrow" || item.kind === "repay"),
          )
          .map((item) => ({
            timestamp: item.timestamp,
            deltaUsd: (item.kind === "borrow" ? 1 : -1) * (Number(item.executedAmountUsd6) / 1_000_000),
          })),
      )
    }
    if (activeMetricTab === metricTabs[1]) {
      return (
        detail.heroBorrowedFeed ?? buildFeedFromRangeSeries(detail.heroMetric.series.borrow, "usdCompact", fallback)
      )
    }
    if (activeMetricTab === metricTabs[2]) {
      return (
        detail.heroUtilizationFeed ??
        buildFeedFromRangeSeries(detail.heroMetric.series.utilization, "percent", fallback)
      )
    }
    return (
      detail.heroFeed ??
      buildFeedFromRangeSeries(detail.heroMetric.series.supply, "usdCompact", getAssetHeroFeed(detail.id))
    )
  }, [
    activeMetricTab,
    detail.heroFeed,
    detail.heroBorrowedFeed,
    detail.heroUtilizationFeed,
    detail.heroMetric.series,
    detail.hero.symbol,
    detail.id,
    metricTabs,
    portfolioBorrow,
    session.state,
    session.transactionHistory,
    walletId,
  ])

  return (
    <section className={cn("flex flex-col gap-5", className)} data-testid="asset-hero">
      {hideIdentity ? null : <AssetHeroIdentity detail={detail} leading={leading} actions={actions} />}

      <div className="pt-4" data-testid="asset-hero-chart-card">
        <MarketHeroChart
          feed={feed}
          defaultRange="1M"
          hideIntradayRange
          gradientId={`assetHeroFill-${detail.id}`}
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
