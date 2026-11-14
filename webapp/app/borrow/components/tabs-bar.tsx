"use client"

import type { Dispatch, SetStateAction } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { MarketFiltersBar } from "@/app/lib/ui/market-filters"
import {
  BORROW_MARKET_OPTIONS,
  type AssetOption,
  type FilterableItem,
  type MarketFilterState,
} from "@/app/lib/markets/filters"

type TabsBarProps = {
  items: readonly FilterableItem[]
  filters: MarketFilterState
  onFiltersChange: Dispatch<SetStateAction<MarketFilterState>>
  assetOptions: readonly AssetOption[]
  search: string
  onSearchChange: (value: string) => void
}

/** Borrow's filter row: chains, hubs, DEX markets and LP assets, plus the market search. */
export function TabsBar({ items, filters, onFiltersChange, assetOptions, search, onSearchChange }: TabsBarProps) {
  const { t } = useTranslation()

  return (
    <div className="z-30 py-7 md:py-7">
      <MarketFiltersBar
        items={items}
        value={filters}
        onChange={onFiltersChange}
        marketOptions={BORROW_MARKET_OPTIONS}
        assetOptions={assetOptions}
        search={search}
        onSearchChange={onSearchChange}
        searchPlaceholder={t("Filter markets")}
      />
    </div>
  )
}
