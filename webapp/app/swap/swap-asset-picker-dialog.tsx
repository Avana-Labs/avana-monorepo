"use client"

import { useMemo, useState } from "react"
import { Search } from "@/app/components/icons"
import { SwapAssetIcon } from "@/app/swap/swap-asset-icon"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import type { SwapAsset, UserAssetBalance } from "@/app/lib/swap-system"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"

export function SwapAssetPickerDialog({
  open,
  onOpenChange,
  title,
  assets,
  balances,
  selectedAssetId,
  excludedAssetId,
  onSelect,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  assets: SwapAsset[]
  balances: UserAssetBalance[]
  selectedAssetId: string
  excludedAssetId: string
  onSelect: (assetId: string) => void
}) {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const canonicalPriceFor = useCanonicalPriceFor()
  const [query, setQuery] = useState("")
  const filteredAssets = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return assets.filter(
      (asset) =>
        asset.id !== excludedAssetId &&
        (!normalized ||
          asset.symbol.toLowerCase().includes(normalized) ||
          asset.name.toLowerCase().includes(normalized)),
    )
  }, [assets, excludedAssetId, query])

  return (
    <Dialog
      open={open}
      onOpenChange={(nextOpen) => {
        onOpenChange(nextOpen)
        if (!nextOpen) setQuery("")
      }}
    >
      <DialogContent className="max-h-[min(620px,calc(100dvh-96px))] w-full max-w-[600px] gap-0 overflow-hidden rounded-radius-xl border-border bg-background p-0 shadow-[0_24px_80px_rgba(15,23,42,0.22)] sm:w-[calc(100vw-24px)] sm:rounded-radius-xl [&>button]:right-3.5 [&>button]:top-3.5 [&>button]:rounded-full">
        <DialogTitle className="sr-only">{t(title)}</DialogTitle>
        <DialogDescription className="sr-only">{t("Select an asset for this swap.")}</DialogDescription>

        <div className="flex items-center gap-3 border-b border-border px-4 py-3">
          <Search className="h-[18px] w-[18px] shrink-0 text-muted-foreground" />
          <input
            autoFocus
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("Find an asset")}
            aria-label={t("Find an asset")}
            className="h-8 min-w-0 flex-1 bg-transparent text-[16px] font-normal text-foreground outline-none placeholder:text-muted-foreground"
          />
        </div>

        <div className="flex items-center gap-2 border-b border-border px-5 py-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
          <span>{t("Supported assets")}</span>
          <span className="ml-auto rounded-full bg-surface-inset px-1.5 py-0.5 text-[10px] font-medium tabular-nums text-muted-foreground/80">
            {filteredAssets.length}
          </span>
        </div>
        <div role="listbox" aria-label={t("Supported assets")} className="max-h-[430px] overflow-y-auto px-2 py-2.5">
          {filteredAssets.map((asset) => {
            const balance = balances.find((item) => item.assetId === asset.id && item.sourceType === "wallet")?.amount
            const amount = balance ?? 0
            return (
              <button
                key={asset.id}
                type="button"
                role="option"
                aria-selected={asset.id === selectedAssetId}
                aria-label={`${asset.name} (${asset.symbol})`}
                onClick={() => {
                  onSelect(asset.id)
                  onOpenChange(false)
                  setQuery("")
                }}
                className="group flex w-full items-center gap-3 rounded-radius-md px-3 py-2 text-left transition-colors hover:bg-hover aria-selected:bg-surface-inset"
              >
                <SwapAssetIcon asset={asset} className="size-8" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-medium text-foreground">{asset.name}</span>
                  <span className="block truncate text-[12px] leading-5 text-muted-foreground">{asset.symbol}</span>
                </span>
                <span className="text-right">
                  <span className="block font-data text-[13px] font-medium text-foreground">
                    {amount.toLocaleString(undefined, { maximumFractionDigits: 6 })} {asset.symbol}
                  </span>
                  <span className="block font-data text-[12px] text-muted-foreground">
                    {exact(amount * (canonicalPriceFor(asset.symbol) ?? asset.priceUsd))}
                  </span>
                </span>
                {asset.id === selectedAssetId ? <span className="sr-only">{t("Selected")}</span> : null}
              </button>
            )
          })}
          {filteredAssets.length === 0 ? (
            <div className="px-4 py-10 text-center text-[13px] text-muted-foreground">{t("No assets found.")}</div>
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  )
}
