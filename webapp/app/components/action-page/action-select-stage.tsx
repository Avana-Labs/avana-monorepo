"use client"

import { useMemo, useState } from "react"
import { ChevronRight, Search } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ActionTokenIcon, ActionTokenPairIcon } from "@/app/components/action-page/action-token-icon"
import Link from "next/link"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import { TRANSACT_ACCESS_HREF, useTransactAccessCta } from "@/app/lib/transact-access"

type ActionSelectItem = {
  id: string
  name: string
  symbol: string
  sublabel?: string
  trailingLabel: string
  trailingSublabel?: string
  pairSymbols?: [string, string]
}

export function ActionSelectStage({
  items,
  onSelect,
  searchPlaceholder = "Find an asset",
  emptyTitle = "No assets found",
  emptyDescription = "Try adjusting your search",
}: {
  items: ActionSelectItem[]
  onSelect: (id: string) => void
  sectionLabel?: string
  searchPlaceholder?: string
  emptyTitle?: string
  emptyDescription?: string
}) {
  const { t } = useTranslation()
  // A guest's empty list (no wallet, so no assets) was a dead end; offer the same CTA as the
  // configure stage and detail pages.
  const accessCta = useTransactAccessCta()
  const accessLabel = accessCta.label
  const [query, setQuery] = useState("")
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return items
    return items.filter(
      (item) =>
        item.name.toLowerCase().includes(needle) ||
        item.symbol.toLowerCase().includes(needle) ||
        item.sublabel?.toLowerCase().includes(needle),
    )
  }, [items, query])

  return (
    <div data-testid="action-select-stage">
      <label className="relative block">
        <span className="sr-only">{t(searchPlaceholder)}</span>
        <Search
          className="pointer-events-none absolute left-4 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t(searchPlaceholder)}
          className="h-11 w-full rounded-full border border-[#e6e6e6] bg-[#fafafa] pl-11 pr-4 text-[14px] font-normal tracking-[-0.01em] text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-foreground/20 dark:border-border/60 dark:bg-surface-2 dark:focus:border-brand/30"
        />
      </label>

      <div className="mt-3 flex flex-col gap-0.5">
        {filtered.length === 0 ? (
          <div className="px-4 py-8 text-center">
            <div className="text-[14px] font-medium">{t(emptyTitle)}</div>
            <div className="mt-1 text-[13px] text-muted-foreground">{t(emptyDescription)}</div>
            {accessLabel && !query.trim() ? (
              <Link
                href={TRANSACT_ACCESS_HREF}
                onClick={accessCta.onClick}
                className={primaryCtaClass({ size: "compact", className: "mt-4 inline-flex px-6 font-normal" })}
              >
                {t(accessLabel)}
              </Link>
            ) : null}
          </div>
        ) : (
          filtered.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => onSelect(item.id)}
              className={cn(
                "group flex w-full items-center justify-between gap-4 rounded-radius-md px-3 py-3 text-left transition-colors",
                "hover:bg-hover",
              )}
            >
              <div className="flex min-w-0 items-center gap-3">
                {item.pairSymbols ? (
                  <ActionTokenPairIcon
                    collateralSymbol={item.pairSymbols[0]}
                    borrowSymbol={item.pairSymbols[1]}
                    size="md"
                  />
                ) : (
                  <ActionTokenIcon symbol={item.symbol} />
                )}
                <div className="min-w-0">
                  <div className="truncate text-[14px] font-medium">{item.name}</div>
                  <div className="truncate text-[13px] text-muted-foreground">{item.sublabel ?? item.symbol}</div>
                </div>
              </div>
              <div className="flex shrink-0 items-center gap-2.5">
                <div className="text-right">
                  <div className="text-[14px] font-medium text-foreground">{item.trailingLabel}</div>
                  {item.trailingSublabel ? (
                    <div className="mt-0.5 text-[13px] text-muted-foreground">{item.trailingSublabel}</div>
                  ) : null}
                </div>
                <ChevronRight
                  className="size-4 shrink-0 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100"
                  aria-hidden
                />
              </div>
            </button>
          ))
        )}
      </div>
    </div>
  )
}
