"use client"

import { useEffect, useState } from "react"
import { Heart } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { AnimatedTextValue } from "@/app/components/action-page/action-live-value"
import {
  HF_ZONES,
  activeHealthFactorZoneIndex,
  healthFactorBarPositionPct,
  healthFactorBarTone,
  healthFactorStatusLabel,
} from "@/app/lib/action-system/health-factor-ui"
import { formatActionHealthFactor } from "@/app/lib/action-system/formatters"

export function HealthFactorPositionBar({
  value,
  className,
  trackClassName = "bg-muted",
  heightClassName = "h-2",
}: {
  value: number | null
  className?: string
  trackClassName?: string
  heightClassName?: string
}) {
  const [displayValue, setDisplayValue] = useState<number | null>(() =>
    value == null || Number.isNaN(value) ? null : value,
  )

  useEffect(() => {
    if (value == null || Number.isNaN(value)) {
      setDisplayValue(value)
      return undefined
    }

    setDisplayValue(value)
    return undefined
  }, [value])

  const fillPct = healthFactorBarPositionPct(displayValue)
  const barTone = healthFactorBarTone(displayValue)
  const hasValue = displayValue != null && !Number.isNaN(displayValue) && activeHealthFactorZoneIndex(displayValue) >= 0

  return (
    <div className={cn("relative rounded-full", trackClassName, heightClassName, className)}>
      {hasValue ? (
        <>
          <div
            className={cn(
              "absolute inset-y-0 left-0 rounded-full transition-[width,left] duration-500 ease-out",
              barTone.fill,
            )}
            style={{ width: `${fillPct}%` }}
            aria-hidden
          />
          <span
            className={cn(
              "absolute top-1/2 size-3 -translate-y-1/2 rounded-full border-2 bg-background transition-[left] duration-500 ease-out",
              barTone.border,
            )}
            style={{ left: `calc(${fillPct}% - 6px)` }}
            aria-hidden
          />
        </>
      ) : null}
    </div>
  )
}

export function ActionHealthFactorBar({
  value,
  label = "Health factor",
  className,
}: {
  value: number | null
  label?: string
  className?: string
}) {
  const { t } = useTranslation()
  const status = healthFactorStatusLabel(value)
  const activeZoneIdx = activeHealthFactorZoneIndex(value)
  const valueLabel = value == null ? "—" : formatActionHealthFactor(value)

  return (
    <div className={cn("space-y-3", className)} data-testid="action-health-factor-bar">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-1.5 text-[14px] text-muted-foreground">
          <Heart
            className={cn(
              "size-3.5",
              status.tone === "positive" && "fill-emerald-500 text-emerald-500",
              status.tone === "warning" && "fill-amber-500 text-amber-500",
              status.tone === "danger" && "fill-rose-500 text-rose-500",
            )}
            aria-hidden
          />
          <span>{t(label)}</span>
          <ActionMetricHelp
            topic={label}
            text="Health factor estimates how far your position is from liquidation. Above 1.0 is solvent; below 1.0 can be liquidated."
          />
        </div>
        <span
          className={cn(
            "inline-flex items-center gap-1.5 rounded-full bg-surface-inset px-2.5 py-0.5 text-[11px] font-semibold uppercase tracking-wide",
            status.tone === "positive" && "text-success",
            status.tone === "warning" && "text-amber-600 dark:text-amber-400",
            status.tone === "danger" && "text-rose-600 dark:text-rose-400",
          )}
        >
          {t(status.label)}
        </span>
      </div>

      <div
        className="font-data text-[20px] font-semibold leading-none tracking-tight text-foreground"
        aria-live="polite"
        aria-atomic="true"
      >
        <AnimatedTextValue text={valueLabel} animateOnMount />
      </div>

      <HealthFactorPositionBar value={value} className="mt-1" />

      <div className="flex items-center justify-between text-[12px] font-medium text-muted-foreground">
        {HF_ZONES.map((zone, index) => (
          <span
            key={zone.id}
            className={cn("inline-flex items-center gap-1.5", index === activeZoneIdx && "text-foreground")}
          >
            <span
              className={cn("size-2 rounded-full", index === activeZoneIdx ? zone.color : "bg-muted-foreground/50")}
            />
            {t(zone.label)}
          </span>
        ))}
      </div>
    </div>
  )
}
