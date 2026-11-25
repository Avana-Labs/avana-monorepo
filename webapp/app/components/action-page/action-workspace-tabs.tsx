"use client"

import { useTranslation } from "@/app/lib/i18n/use-translation"
import { PillTabStrip } from "@/app/components/tab-primitives"
import { ActionIcon } from "@/app/components/action-icon"

type ActionWorkspaceTabItem = {
  id: string
  label: string
  action?: string
}

export function ActionWorkspaceTabs({
  items,
  value,
  onChange,
  ariaLabel,
  className,
  withIcons = false,
  revealLabels = false,
}: {
  items: ActionWorkspaceTabItem[]
  value: string
  onChange: (value: string) => void
  ariaLabel: string
  className?: string
  withIcons?: boolean
  revealLabels?: boolean
}) {
  const { t } = useTranslation()

  return (
    <PillTabStrip
      items={items.map((item) => {
        const label = t(item.label)
        const action = item.action ?? item.id
        return {
          ...item,
          label: withIcons ? (
            <span className="inline-flex items-center gap-2.5">
              <ActionIcon label={action} className="size-5" />
              <span className={revealLabels ? "home-reveal-tab-label" : undefined}>{label}</span>
            </span>
          ) : (
            label
          ),
        }
      })}
      value={value}
      onChange={onChange}
      ariaLabel={t(ariaLabel)}
      className={className}
      tabClassName={
        revealLabels
          ? // Active width follows label content (w-max) so localized verbs like
            // JA スワップ / ES Intercambiar are not clipped by English-tuned px widths.
            "home-reveal-tab h-10 w-10 overflow-hidden px-0 py-2 text-[14px] font-normal text-muted-foreground data-[state=active]:w-max data-[state=active]:max-w-full data-[state=active]:px-3.5 [&_svg]:size-4"
          : withIcons
            ? "px-3.5 py-2 text-[14px] font-normal text-muted-foreground sm:px-3.5 sm:text-[14px] data-[state=active]:bg-neutral-200 data-[state=active]:text-foreground dark:data-[state=active]:bg-neutral-800 [&_svg]:size-4"
            : undefined
      }
    />
  )
}
