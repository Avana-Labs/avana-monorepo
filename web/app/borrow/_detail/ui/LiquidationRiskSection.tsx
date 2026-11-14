"use client"

import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import type { LiquidationRiskStat } from "@/app/lib/detail-page/liquidation-risk"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type Props = {
  stats: LiquidationRiskStat[]
  className?: string
}

function DeltaArrow({
  deltaValue,
  deltaLabel,
  goodDirection,
}: {
  deltaValue: number
  deltaLabel: string
  goodDirection: "up" | "down"
}) {
  if (!Number.isFinite(deltaValue) || deltaValue === 0) return null
  const direction = deltaValue > 0 ? "up" : "down"
  const isGood = direction === goodDirection
  return (
    <span
      className={cn(
        "inline-flex items-center gap-0.5 font-data text-[12px] font-normal tabular-nums",
        isGood ? "text-success" : "text-rose-500",
      )}
    >
      <span className="text-[10px] leading-none">{direction === "up" ? "▲" : "▼"}</span>
      {deltaLabel}
    </span>
  )
}

/**
 * Market Liquidation Risk — Key-Statistics-style grid with small daily ▲/▼ deltas.
 * Borrow pool + Multiply detail only.
 */
export function LiquidationRiskSection({ stats, className }: Props) {
  const { t } = useTranslation()
  if (stats.length === 0) return null

  return (
    <section aria-label={t("Liquidation Risk")} className={cn("min-w-0", className)}>
      <div className="mb-6 flex items-center gap-1.5">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
          {t("Liquidation Risk")}
        </h2>
        <ActionMetricHelp
          text={t("Market-wide liquidation activity and near-liquidation exposure over the last 24 hours.")}
          topic="Liquidation Risk"
        />
      </div>

      <div className="grid w-full grid-cols-2 gap-x-6 gap-y-6 sm:grid-cols-3 md:gap-x-10">
        {stats.map((stat) => (
          <article key={stat.id} className="min-w-0">
            <div className="flex items-center gap-1">
              <span className="text-[13px] font-normal leading-snug text-muted-foreground">{t(stat.label)}</span>
            </div>
            <div className="mt-1.5 flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <span className="font-data text-[20px] font-normal leading-none tracking-[-0.01em] text-foreground md:text-[22px]">
                {stat.value}
              </span>
              <DeltaArrow
                deltaValue={stat.deltaValue}
                deltaLabel={stat.deltaLabel}
                goodDirection={stat.goodDirection}
              />
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}
