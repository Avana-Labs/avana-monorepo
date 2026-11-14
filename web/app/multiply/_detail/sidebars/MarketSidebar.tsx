"use client"

import * as React from "react"
import type { MultiplyMarketDetail } from "@/app/lib/multiply-detail"
import { ActionPageLaunchCta } from "@/app/components/action-page/action-page-launch-cta"
import { ResponsiveMultiplyAction } from "@/app/components/action-page/responsive-multiply-action"
import { DetailActionTabs } from "@/app/components/detail-action-tabs"
import { getMultiplyMarketById } from "@/app/lib/multiply-system/catalog"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type Props = { detail: MultiplyMarketDetail; className?: string; hideActions?: boolean }

type SidebarTab = "multiply" | "deleverage" | "close"

const MULTIPLY_TAB_ITEMS = [
  { id: "multiply", label: "Multiply" },
  { id: "deleverage", label: "Deleverage" },
  { id: "close", label: "Close" },
] as const

function normalizeMarketId(id: string) {
  return id.toLowerCase().replaceAll("_", "-")
}

export function MarketSidebar({ detail, className, hideActions = false }: Props) {
  const { t } = useTranslation()
  return (
    <aside
      className={cn("flex w-full flex-col gap-12", className)}
      aria-label={t("Multiply {name}").replace("{name}", detail.hero.name)}
    >
      {hideActions ? null : <MarketActionRail detail={detail} className="mt-6" embedActions />}
    </aside>
  )
}

function MarketActionRail({ detail, className, embedActions = false }: Props & { embedActions?: boolean }) {
  const { t } = useTranslation()
  const marketId = normalizeMarketId(detail.id)
  const market = getMultiplyMarketById(marketId)
  const closeHref = `/multiply/markets/${marketId}`

  const [tab, setTab] = React.useState<SidebarTab>("multiply")

  React.useEffect(() => {
    setTab("multiply")
  }, [detail.id])

  // Every market is openable — if the catalog record can't be resolved inline, still
  // route the user into the full-screen multiply action (which resolves it itself)
  // rather than dead-ending on an "unavailable" message.
  if (!market) {
    return (
      <div className={cn("rounded-radius-xl border border-border bg-background px-4 py-5", className)}>
        <p className="text-[15px] leading-6 text-muted-foreground">
          {t("Open a looped position in {name}.").replace("{name}", detail.hero.name)}
        </p>
        <ActionPageLaunchCta
          product="multiply"
          kind="multiply"
          market={marketId}
          className="mt-3 w-full"
          label="Multiply"
        />
      </div>
    )
  }

  return (
    <div className={cn("flex w-full flex-col", className)}>
      <DetailActionTabs items={MULTIPLY_TAB_ITEMS} value={tab} onChange={setTab} ariaLabel="Multiply actions" />

      <div className="mt-3">
        {tab === "multiply" ? (
          embedActions ? (
            <ResponsiveMultiplyAction kind="multiply" market={marketId} closeHref={closeHref} sidebar />
          ) : (
            <ActionPageLaunchCta product="multiply" kind="multiply" market={marketId} returnTo={closeHref} />
          )
        ) : null}

        {tab === "deleverage" ? (
          embedActions ? (
            <ResponsiveMultiplyAction kind="deleverage" market={marketId} closeHref={closeHref} sidebar />
          ) : (
            <ActionPageLaunchCta product="multiply" kind="deleverage" market={marketId} returnTo={closeHref} />
          )
        ) : null}

        {tab === "close" ? (
          embedActions ? (
            <ResponsiveMultiplyAction kind="close" market={marketId} closeHref={closeHref} sidebar />
          ) : (
            <ActionPageLaunchCta product="multiply" kind="close" market={marketId} returnTo={closeHref} />
          )
        ) : null}
      </div>
    </div>
  )
}
