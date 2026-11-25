"use client"

import * as React from "react"
import type { LendMarketDetail } from "@/app/lib/lend-detail"
import { ResponsiveLendAction } from "@/app/components/action-page/responsive-lend-action"
import { DetailActionTabs } from "@/app/components/detail-action-tabs"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type Props = { detail: LendMarketDetail; className?: string }

type SidebarTab = "deposit" | "withdraw"

const LEND_TAB_ITEMS = [
  { id: "deposit", label: "Deposit" },
  { id: "withdraw", label: "Withdraw" },
] as const

export function LendSidebar({ detail, className }: Props) {
  const { t } = useTranslation()
  return (
    <aside
      className={cn("flex w-full flex-col gap-12", className)}
      aria-label={t("Lend {name}").replace("{name}", detail.hero.name)}
    >
      <LendActionRail detail={detail} className="mt-9" />
    </aside>
  )
}

function LendActionRail({ detail, className }: Props) {
  const marketId = detail.row.marketId
  const closeHref = `/lend/markets/${marketId}`
  const [tab, setTab] = React.useState<SidebarTab>("deposit")

  React.useEffect(() => {
    setTab("deposit")
  }, [detail.id])

  return (
    <div className={cn("flex w-full flex-col", className)}>
      <DetailActionTabs items={LEND_TAB_ITEMS} value={tab} onChange={setTab} ariaLabel="Lend actions" />

      <div className="mt-2">
        {/* Keyed per tab so each form mounts fresh. Unkeyed, React reused one instance: after a
            failed deposit the Withdraw tab inherited the amount and the "error" stage, whose
            in-place retry submitted the withdraw without a review step. */}
        {tab === "deposit" ? (
          <ResponsiveLendAction key="deposit" kind="deposit" market={marketId} closeHref={closeHref} sidebar />
        ) : (
          <ResponsiveLendAction key="withdraw" kind="withdraw" market={marketId} closeHref={closeHref} sidebar />
        )}
      </div>
    </div>
  )
}
