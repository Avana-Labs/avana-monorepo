"use client"

import Link from "next/link"
import { CircleArrowOutDownRight, EnteringGeoFence, Repeat2 } from "@/app/components/icons"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { Button } from "@/components/ui/button"

const RETURN_HREF = "/dashboard"

function withReturn(href: string) {
  return `${href}${href.includes("?") ? "&" : "?"}return=${encodeURIComponent(RETURN_HREF)}`
}

export type DashboardQuickActionsTab = "wallet" | "lend" | "borrow" | "rewards"

/** Primary dashboard entry actions. Position-management actions such as Repay
 * and Withdraw stay contextual to their position rows. */
export function DashboardQuickActions(_: { activeTab?: DashboardQuickActionsTab }) {
  const { t } = useTranslation()

  const actions = [
    {
      id: "deposit",
      label: t("Deposit"),
      icon: EnteringGeoFence,
      href: withReturn(actionPagePath("lend", "deposit")),
    },
    {
      id: "borrow",
      label: t("Borrow"),
      icon: CircleArrowOutDownRight,
      href: withReturn(actionPagePath("borrow", "borrow")),
    },
    {
      id: "swap",
      label: t("Swap"),
      icon: Repeat2,
      href: withReturn("/swap"),
    },
  ]

  return (
    <div aria-label={t("Quick actions")} role="group" className="grid w-full grid-cols-2 gap-2 lg:flex lg:w-auto">
      {actions.map((action) => {
        const Icon = action.icon
        return (
          <Button
            key={action.id}
            asChild
            variant="outline"
            size="sm"
            className="w-full gap-2 !rounded-full [&_svg]:size-4 lg:w-auto"
          >
            <Link href={action.href} aria-label={action.label}>
              <Icon aria-hidden />
              <span>{action.label}</span>
            </Link>
          </Button>
        )
      })}
    </div>
  )
}
