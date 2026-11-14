"use client"

import { type ReactNode } from "react"
import type { HomeMode } from "@/app/lib/home-view-model"
import { ActionWorkspaceTabs } from "@/app/components/action-page/action-workspace-tabs"
import { TestnetMetricsBadge } from "@/app/components/testnet-metrics-badge"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export const HOME_MODE_ITEMS: Array<{ value: HomeMode; label: string }> = [
  { value: "swap", label: "Swap" },
  { value: "borrow", label: "Borrow" },
  { value: "repay", label: "Repay" },
  { value: "claim", label: "Claim" },
  { value: "remove", label: "Remove" },
]

export function HomeWorkspaceCard({
  mode,
  onModeChange,
  children,
}: {
  mode: HomeMode
  onModeChange: (mode: HomeMode) => void
  children: ReactNode
}) {
  const { t } = useTranslation()

  return (
    <section className="flex min-h-[calc(100dvh-4rem)] justify-center px-4 pb-12 pt-14 md:pb-16 md:pt-20">
      <div className="w-full max-w-[480px]" data-testid="home-workspace-card">
        <div className="flex items-center justify-between gap-2">
          <ActionWorkspaceTabs
            className="flex-1"
            items={HOME_MODE_ITEMS.map((item) => ({ id: item.value, label: item.label }))}
            value={mode}
            onChange={(value) => onModeChange(value as HomeMode)}
            ariaLabel={t("Express actions")}
            withIcons
            revealLabels
          />
          <TestnetMetricsBadge label={t("Testnet")} size="compact" />
        </div>

        <div className="mt-3 flex flex-col gap-2">{children}</div>
      </div>
    </section>
  )
}
