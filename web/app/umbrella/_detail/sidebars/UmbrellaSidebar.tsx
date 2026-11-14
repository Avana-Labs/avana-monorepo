"use client"

import { useEffect, useMemo, useState } from "react"
import { ResponsiveUmbrellaAction } from "@/app/components/action-page/responsive-umbrella-action"
import { DetailActionTabs } from "@/app/components/detail-action-tabs"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const UMBRELLA_ACTION_TAB_KEYS = [
  { id: "stake", labelKey: "Stake" },
  { id: "claim", labelKey: "Claim" },
  { id: "cooldown", labelKey: "Cooldown" },
  { id: "unstake", labelKey: "Unstake" },
] as const

type UmbrellaActionTab = (typeof UMBRELLA_ACTION_TAB_KEYS)[number]["id"]

export function UmbrellaSidebar({
  moduleId,
  onMarketChange,
  initialTab = "stake",
}: {
  moduleId: UmbrellaMarketId
  onMarketChange?: (marketId: UmbrellaMarketId) => void
  // Which tab to land on for this mount. The mobile sheet remounts the sidebar
  // on every open (via a changing `key`), so this initializer runs afresh each
  // time the sheet is opened — Stake and Unstake mobile CTAs pass their tab here.
  initialTab?: UmbrellaActionTab
}) {
  const { t } = useTranslation()
  const tabs = useMemo(() => UMBRELLA_ACTION_TAB_KEYS.map((entry) => ({ id: entry.id, label: t(entry.labelKey) })), [t])
  const [tab, setTab] = useState<UmbrellaActionTab>(initialTab)
  // Selected market is shared across tabs so switching Stake → Cooldown → Unstake
  // stays on the same asset. The picker inside each embedded action page reports
  // back so the parent can push it into the next tab's initialMarketId.
  const [localMarket, setLocalMarket] = useState<UmbrellaMarketId>(moduleId)
  // Keep in sync when the landing page's selection changes (e.g. user clicks a
  // Positions row) without wiping the picker if the sidebar drove the update.
  useEffect(() => {
    setLocalMarket(moduleId)
  }, [moduleId])
  const closeHref = "/umbrella"

  const handleMarketChange = (nextMarket: UmbrellaMarketId) => {
    setLocalMarket(nextMarket)
    onMarketChange?.(nextMarket)
  }

  return (
    <aside className="flex w-full flex-col" aria-label={t("Umbrella actions")}>
      <DetailActionTabs items={tabs} value={tab} onChange={setTab} ariaLabel={t("Umbrella actions")} />
      <div className="mt-2">
        <ResponsiveUmbrellaAction
          kind={tab}
          market={localMarket}
          closeHref={closeHref}
          sidebar
          onMarketChange={handleMarketChange}
        />
      </div>
    </aside>
  )
}
