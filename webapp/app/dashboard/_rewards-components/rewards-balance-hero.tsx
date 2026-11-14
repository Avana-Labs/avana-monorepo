"use client"

import type { ReactNode } from "react"
import Image from "next/image"
import Link from "next/link"
import { CircleDollarSign } from "@/app/components/icons"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { Button } from "@/components/ui/button"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { DashboardQuickActions, type DashboardQuickActionsTab } from "@/app/dashboard/dashboard-quick-actions"

/**
 * Reward balances are denominated in AVA (the card shows the AVA coin icon), not
 * USD — so format the real earned/claimable totals as AVA amounts rather than a
 * hardcoded "$0". (#26b)
 */
function formatAva(amount: number): string {
  const safe = Number.isFinite(amount) ? amount : 0
  return `${safe.toLocaleString(undefined, { maximumFractionDigits: 0 })} AVA`
}

function AvanaCoin() {
  return (
    <Image
      src="/asset-icons/ava.png"
      alt=""
      width={32}
      height={32}
      sizes="32px"
      className="h-8 w-8 shrink-0 object-contain"
      priority
      aria-hidden
    />
  )
}

function FeeCard({
  label,
  value,
  hidden,
  help,
  action,
}: {
  label: string
  value: string
  hidden: boolean
  help: string
  action?: ReactNode
}) {
  return (
    <div className="rounded-radius-md border-0 bg-card px-4 py-4 dark:bg-white/[0.04]">
      <div className="flex items-center gap-1.5 text-[13px] text-muted-foreground">
        {label}
        <ActionMetricHelp text={help} topic={label} />
      </div>
      <div className="mt-3 flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <AvanaCoin />
          <span className="truncate text-[24px] font-normal leading-none tracking-[-0.01em] text-foreground sm:text-[26px]">
            {hidden ? "••••" : value}
          </span>
        </div>
        {action}
      </div>
    </div>
  )
}

/**
 * The rewards cards (Total Rewards earned / Claimable Rewards + Claim Rewards).
 * Rendered as the hero's right column on desktop and inline near the bottom of
 * the page on mobile, so it's reachable on small screens too.
 */
export function PortfolioRewardsCards({
  claimHref,
  earnedAmount = 0,
  claimableAmount = 0,
  activeTab,
  showQuickActions = false,
}: {
  claimHref?: string
  /** Total AVA earned across completed quests. */
  earnedAmount?: number
  /** AVA currently claimable. */
  claimableAmount?: number
  activeTab?: DashboardQuickActionsTab
  /** When true, render the compact quick-action icon rail under the claim cards. */
  showQuickActions?: boolean
}) {
  const { t } = useTranslation()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  return (
    // No section-level space-y: on desktop only the fee cards render (the rail is
    // lg:hidden), so the rail's own mb-3 owns the mobile gap and desktop stays flush.
    <section className="min-w-0">
      {/* Mobile only — the desktop rail lives in the "Your Dashboard" header. */}
      {showQuickActions ? (
        <div className="mb-6 lg:hidden">
          <DashboardQuickActions activeTab={activeTab} />
        </div>
      ) : null}
      <div className="space-y-3">
        <FeeCard
          label={t("Total Rewards earned")}
          value={formatAva(earnedAmount)}
          hidden={!showDollarAmounts}
          help={t("Total AVA you've earned across completed quests and staking rewards.")}
        />
        <FeeCard
          label={t("Claimable Rewards")}
          value={formatAva(claimableAmount)}
          hidden={!showDollarAmounts}
          help={t("AVA you can claim to your wallet right now.")}
          action={
            claimHref ? (
              <Button asChild size="sm" className="shrink-0 gap-2 font-normal [&_svg]:size-4">
                <Link href={claimHref}>
                  <CircleDollarSign className="size-4" />
                  {t("Claim Rewards")}
                </Link>
              </Button>
            ) : (
              <Button type="button" size="sm" disabled className="shrink-0 gap-2 font-normal [&_svg]:size-4">
                <CircleDollarSign className="size-4" />
                {t("Claim Rewards")}
              </Button>
            )
          }
        />
      </div>
    </section>
  )
}
