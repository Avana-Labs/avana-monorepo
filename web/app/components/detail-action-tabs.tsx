"use client"

import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type DetailActionTabItem<T extends string = string> = {
  id: T
  label: string
}

type Props<T extends string> = {
  items: readonly DetailActionTabItem<T>[]
  value: T
  onChange: (value: T) => void
  ariaLabel: string
  className?: string
}

export function DetailActionTabs<T extends string>({ items, value, onChange, ariaLabel, className }: Props<T>) {
  const { t } = useTranslation()

  return (
    <div
      role="tablist"
      aria-label={t(ariaLabel)}
      className={cn(
        "flex max-w-full items-center gap-0 overflow-x-auto whitespace-nowrap [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
        className,
      )}
    >
      {items.map((item) => {
        const active = value === item.id
        return (
          <button
            key={item.id}
            type="button"
            role="tab"
            aria-selected={active}
            data-state={active ? "active" : "inactive"}
            onClick={() => onChange(item.id)}
            className={cn(
              "shrink-0 rounded-full px-2.5 py-2 text-[14px] font-normal leading-5 text-foreground/65 transition-colors hover:text-foreground sm:px-3.5 sm:text-[15px]",
              active && "bg-muted px-3 py-2.5 text-foreground sm:px-4",
            )}
          >
            {t(item.label)}
          </button>
        )
      })}
    </div>
  )
}
