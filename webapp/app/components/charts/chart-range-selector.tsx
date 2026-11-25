"use client"

import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { CHART_RANGE_OPTIONS, type ChartRangeOption } from "./types"

type ChartRangeSelectorProps = {
  activeRange: ChartRangeOption
  onRangeChange: (range: ChartRangeOption) => void
  className?: string
  /** Ranges to render. Defaults to all; pass a subset to hide ranges without real data. */
  ranges?: readonly ChartRangeOption[]
}

function formatRangeLabel(range: ChartRangeOption): string {
  return range
}

export function ChartRangeSelector({
  activeRange,
  onRangeChange,
  className,
  ranges = CHART_RANGE_OPTIONS,
}: ChartRangeSelectorProps) {
  const { t } = useTranslation()
  return (
    <div
      role="tablist"
      aria-label={t("Time range")}
      className={cn(
        "inline-flex w-fit items-center gap-0.5 rounded-full border border-border bg-background p-0.5",
        className,
      )}
    >
      {ranges.map((range) => {
        const active = activeRange === range
        return (
          <button
            key={range}
            role="tab"
            aria-selected={active}
            type="button"
            onClick={() => onRangeChange(range)}
            className={cn(
              "relative flex h-6 min-w-[26px] flex-none items-center justify-center rounded-full px-1.5 text-[10px] font-semibold tabular-nums transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/70 focus-visible:ring-offset-2 focus-visible:ring-offset-background sm:text-[10.5px]",
              active ? "bg-muted text-foreground" : "text-foreground/75 hover:text-foreground",
            )}
          >
            {formatRangeLabel(range)}
          </button>
        )
      })}
    </div>
  )
}
