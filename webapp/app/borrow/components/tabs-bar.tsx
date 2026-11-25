"use client"

import type { Dispatch, SetStateAction } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { MarketFiltersBar } from "@/app/lib/ui/market-filters"
import type { AssetOption, FilterableItem, FilterOption, MarketFilterState } from "@/app/lib/markets/filters"

type TabsBarProps = {
  items: readonly FilterableItem[]
  /** The page's CDP Spokes (`borrowSpokeOptions`). */
  marketOptions: ReadonlyArray<FilterOption>
  filters: MarketFilterState
  onFiltersChange: Dispatch<SetStateAction<MarketFilterState>>
  assetOptions: readonly AssetOption[]
  search: string
  onSearchChange: (value: string) => void
}

/** Borrow's filter row: chains, hubs, DEX markets and LP assets, plus the market search. */
export function TabsBar({ items, marketOptions, filters, onFiltersChange, assetOptions, search, onSearchChange }: TabsBarProps) {
  const { t } = useTranslation()

  return (
    <div className="z-30 py-7 md:py-7">
      <MarketFiltersBar
        items={items}
        value={filters}
        onChange={onFiltersChange}
        marketOptions={marketOptions}
        assetOptions={assetOptions}
        search={search}
        onSearchChange={onSearchChange}
        searchPlaceholder={t("Filter markets")}
      />
    </div>
  )
}
