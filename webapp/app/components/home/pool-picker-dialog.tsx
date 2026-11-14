"use client"

import { Check } from "@/app/components/icons"
import { getHealthStatus, type HomeCollateralPool } from "@/app/lib/home-view-model"
import { PairVisual } from "@/app/components/home-workspace-primitives"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { cn } from "@/lib/utils"
import { computeHealthFactor } from "./shared"
import type { PoolDialogMode } from "./types"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"

// Mirror the search-command popup exactly so the pickers share its look/feel.
const PICKER_CONTENT_CLASS =
  "flex max-h-[min(620px,calc(100dvh-96px))] w-full max-w-[600px] flex-col gap-0 overflow-hidden rounded-radius-xl border-border bg-background p-0 shadow-[0_24px_80px_rgba(15,23,42,0.22)] sm:w-[calc(100vw-24px)] sm:max-w-[600px] sm:rounded-radius-xl [&>button]:right-3.5 [&>button]:top-3.5 [&>button]:rounded-full"

export function PoolPickerDialog({
  open,
  onOpenChange,
  selectedPoolId,
  onSelect,
  mode,
  pools,
  debts,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  selectedPoolId: string
  onSelect: (poolId: string) => void
  mode: PoolDialogMode
  pools: HomeCollateralPool[]
  debts: Record<string, number>
}) {
  const { compact } = useCurrency()
  const { t } = useTranslation()

  const title =
    mode === "repay"
      ? t("Select debt position")
      : mode === "remove"
        ? t("Select collateral position")
        : t("Choose collateral")

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className={PICKER_CONTENT_CLASS}>
        <DialogHeader className="border-b border-border px-5 pb-3 pt-4 text-left">
          <DialogTitle className="text-[14px] font-normal leading-5">{title}</DialogTitle>
        </DialogHeader>

        <div className="flex-1 overflow-y-auto py-1.5">
          {pools.map((pool) => {
            const isSelected = pool.id === selectedPoolId
            const debtUsd = debts[pool.id] ?? 0
            const hf = computeHealthFactor(pool, debtUsd)
            const status = getHealthStatus(hf)

            return (
              <button
                key={pool.id}
                type="button"
                onClick={() => {
                  onSelect(pool.id)
                  onOpenChange(false)
                }}
                className={cn(
                  "flex w-full items-center gap-4 px-5 py-2.5 text-left transition-colors hover:bg-hover",
                  isSelected && "bg-surface-inset",
                )}
              >
                <PairVisual visuals={pool.visuals} />
                <div className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate text-[14px] font-normal leading-5 text-foreground">{pool.name}</span>
                  <span className="text-[12px] leading-4 text-muted-foreground">
                    {pool.venue} · {t("Max LTV")} {pool.maxLtv}%
                  </span>
                </div>
                <div className="flex flex-col items-end">
                  <span className="font-data text-[13px] font-normal tabular-nums">
                    {mode === "repay" ? (debtUsd > 0 ? compact(debtUsd) : t("No debt")) : compact(pool.collateralUsd)}
                  </span>
                  {/* The value is the credit shared across this pool's group (e.g. every Uniswap
                      v2 pool), which read as LP the wallet holds in this pool. */}
                  {mode !== "repay" && pool.ownCollateralUsd === 0 && pool.collateralUsd > 0 ? (
                    <span className="text-[11px] leading-4 text-muted-foreground">{t("Shared credit")}</span>
                  ) : null}
                  <span
                    className={cn("inline-flex items-center gap-1 text-[11px] font-normal leading-4", status.textClass)}
                  >
                    <span className={cn("inline-block size-1.5 rounded-full", status.dotClass)} />
                    {t("HF")} {Number.isFinite(hf) ? hf.toFixed(2) : "∞"}
                  </span>
                </div>
                {isSelected ? <Check className="ml-1 h-3.5 w-3.5 text-foreground" /> : null}
              </button>
            )
          })}
        </div>
      </DialogContent>
    </Dialog>
  )
}
