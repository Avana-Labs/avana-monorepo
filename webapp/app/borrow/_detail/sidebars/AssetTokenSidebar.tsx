"use client"

import * as React from "react"
import { cn } from "@/lib/utils"
import type { AssetDetail } from "@/app/lib/borrow-detail"
import { ActionPageLaunchCta } from "@/app/components/action-page/action-page-launch-cta"
import { ResponsiveBorrowAction } from "@/app/components/action-page/responsive-borrow-action"
import { DetailActionTabs } from "@/app/components/detail-action-tabs"
import { useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import type { HomeAssetVisual, HomeCollateralPool } from "@/app/lib/borrow-system/home-contracts"
import type { BorrowPoolRow } from "@/app/lib/data/borrow-domain"

type Props = { detail: AssetDetail; className?: string }

type SidebarTab = "borrow" | "repay"

const ASSET_TAB_ITEMS = [
  { id: "borrow", label: "Borrow" },
  { id: "repay", label: "Repay" },
] as const

export function AssetTokenSidebar({ detail, className }: Props) {
  return (
    <div className={cn("flex w-full flex-col gap-12", className)}>
      <TokenRail detail={detail} className="mt-6" embedActions />
    </div>
  )
}

export function AssetTokenActions({ detail, className }: Props) {
  return <TokenRail detail={detail} className={className} />
}

function TokenRail({
  detail,
  className,
  embedActions = false,
}: {
  detail: AssetDetail
  className?: string
  embedActions?: boolean
}) {
  // Borrow-section asset detail: always show the normal Borrow/Repay action card.
  // Missing collateral is handled inline on the card via ActionOutcomeBanner.
  const [tab, setTab] = React.useState<SidebarTab>("borrow")
  const closeHref = `/borrow/assets/${detail.row.id}`
  const session = useBorrowSessionContext()
  const fallbackMarket = React.useMemo(
    () => session.marketSummaries.find((market) => detail.row.marketIds.includes(market.id)) ?? null,
    [detail.row.marketIds, session.marketSummaries],
  )
  const borrowContext = React.useMemo<HomeCollateralPool | null>(() => {
    const suppliedPool = session.collateralPools.find((pool) => detail.row.marketIds.includes(pool.id))
    if (suppliedPool) return suppliedPool
    return fallbackMarket ? toHomeCollateralPool(fallbackMarket) : null
  }, [detail.row.marketIds, fallbackMarket, session.collateralPools])

  React.useEffect(() => {
    setTab("borrow")
  }, [detail.id])

  if (!borrowContext) {
    return (
      <div className={cn("flex w-full flex-col", className)}>
        <DetailActionTabs items={ASSET_TAB_ITEMS} value={tab} onChange={setTab} ariaLabel="Asset actions" />
      </div>
    )
  }

  return (
    <div className={cn("flex w-full flex-col", className)}>
      <DetailActionTabs items={ASSET_TAB_ITEMS} value={tab} onChange={setTab} ariaLabel="Asset actions" />

      <div className="mt-3">
        {tab === "borrow" ? (
          embedActions ? (
            <ResponsiveBorrowAction
              kind="borrow"
              market={borrowContext.id}
              asset={detail.row.id}
              closeHref={closeHref}
              sidebar
            />
          ) : (
            <ActionPageLaunchCta
              product="borrow"
              kind="borrow"
              market={borrowContext.id}
              asset={detail.row.id}
              returnTo={closeHref}
            />
          )
        ) : null}

        {tab === "repay" ? (
          embedActions ? (
            <ResponsiveBorrowAction
              kind="repay"
              market={borrowContext.id}
              asset={detail.row.id}
              closeHref={closeHref}
              sidebar
            />
          ) : (
            <ActionPageLaunchCta
              product="borrow"
              kind="repay"
              market={borrowContext.id}
              asset={detail.row.id}
              returnTo={closeHref}
            />
          )
        ) : null}
      </div>
    </div>
  )
}

function toHomeCollateralPool(row: BorrowPoolRow): HomeCollateralPool {
  return {
    id: row.id,
    name: row.name,
    venue: row.venue,
    category: row.feeTier,
    collateralUsd: row.collateralExampleUsd,
    maxLtv: row.ltv,
    borrowPowerUsd: Math.round(row.collateralExampleUsd * (row.ltv / 100)),
    liquidationUsd: Math.round(row.collateralExampleUsd * ((row.ltv + 10) / 100)),
    pairApr: (row.aprMin + row.aprMax) / 2,
    visuals: row.visuals.map((visual) => ({
      symbol: visual.symbol,
      shortLabel: visual.shortLabel,
      bgClassName: visual.bgClass,
      textClassName: visual.textClass,
    })) as [HomeAssetVisual, HomeAssetVisual],
  }
}
