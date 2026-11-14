"use client"

import type { ReactNode } from "react"
import { cn } from "@/lib/utils"

type SharedTabItem<T extends string> = {
  id: T
  label: ReactNode
}

/**
 * Pill tabs use CSS for the active-state and press feedback. Framer-motion used to ship
 * on this path (the home workspace indicator) and pulled ~the motion runtime into the
 * first-load JS for every `/` visitor — a CSS `active:scale` is enough.
 */
export function PillTabStrip<T extends string>({
  items,
  value,
  onChange,
  ariaLabel,
  className,
  tabClassName,
}: {
  items: readonly SharedTabItem<T>[]
  value: T
  onChange: (value: T) => void
  ariaLabel: string
  className?: string
  tabClassName?: string
}) {
  return (
    <div
      role="tablist"
      aria-label={ariaLabel}
      className={cn(
        "flex min-w-0 flex-nowrap items-center gap-0.5 overflow-x-auto sm:gap-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
        className,
      )}
    >
      {items.map((item) => {
        const active = item.id === value
        return (
          <button
            key={item.id}
            type="button"
            role="tab"
            aria-selected={active}
            data-state={active ? "active" : "inactive"}
            onClick={() => onChange(item.id)}
            className={cn(
              "group shrink-0 whitespace-nowrap rounded-full px-2.5 py-1.5 text-[14px] font-medium leading-none transition-[color,background-color,transform] duration-150 ease-out will-change-transform active:scale-[0.96] motion-reduce:transition-none motion-reduce:active:scale-100 sm:px-3 sm:text-[15px]",
              active ? "bg-field-bottom text-foreground" : "text-muted-foreground hover:text-foreground",
              tabClassName,
            )}
          >
            {item.label}
          </button>
        )
      })}
    </div>
  )
}

export function UnderlineTabStrip<T extends string>({
  items,
  value,
  onChange,
  ariaLabel,
  className,
  listClassName,
  tabClassName,
}: {
  items: readonly SharedTabItem<T>[]
  value: T
  onChange: (value: T) => void
  ariaLabel: string
  className?: string
  listClassName?: string
  tabClassName?: string
}) {
  return (
    <div
      className={cn(
        "max-w-full overflow-x-auto overscroll-x-contain border-b border-border/90 [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden",
        className,
      )}
    >
      <div
        role="tablist"
        aria-label={ariaLabel}
        className={cn(
          "flex h-auto w-full justify-between gap-2 border-0 bg-transparent p-0 sm:inline-flex sm:w-max sm:min-w-max sm:justify-start sm:gap-9",
          listClassName,
        )}
      >
        {items.map((item) => {
          const active = item.id === value
          return (
            <button
              key={item.id}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onChange(item.id)}
              data-state={active ? "active" : "inactive"}
              className={cn(
                "relative h-auto shrink-0 rounded-none border-0 px-0 pb-3 pt-0 text-[15px] font-normal text-muted-foreground transition-colors after:absolute after:bottom-0 after:left-0 after:h-[3px] after:w-full after:rounded-full after:bg-transparent sm:pb-4",
                active ? "text-[16px] text-foreground after:bg-foreground" : "hover:text-foreground",
                tabClassName,
              )}
            >
              {item.label}
            </button>
          )
        })}
      </div>
    </div>
  )
}
