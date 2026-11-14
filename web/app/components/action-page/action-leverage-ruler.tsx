"use client"

import { useCallback, useMemo } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { Slider } from "@/components/ui/slider"
import { cn } from "@/lib/utils"

const SCALE_TICK_COUNT = 5
const DEFAULT_MIN = 1
const DEFAULT_MAX = 9.99
const DEFAULT_STEP = 0.01

/** Pill / live value — up to 2 decimals, trim trailing zeros (1x, 6.7x, 9.99x). */
function formatMultiplier(value: number) {
  if (!Number.isFinite(value)) return "—x"
  const rounded = Math.round(value * 100) / 100
  if (Number.isInteger(rounded)) return `${rounded}x`
  const fixed = rounded.toFixed(2).replace(/\.?0+$/, "")
  return `${fixed}x`
}

function formatRulerValue(value: number, suffix?: string) {
  if (!suffix) return formatMultiplier(value)
  const rounded = Math.round(value * 100) / 100
  const formatted = Number.isInteger(rounded)
    ? String(rounded)
    : rounded.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
  return `${formatted}${suffix}`
}

/** Scale labels — same rounding as the mock (3.25x, 5.5x, 7.74x, 9.99x). */
function formatTickLabel(value: number) {
  if (!Number.isFinite(value)) return "—"
  const rounded = Math.round(value * 100) / 100
  if (Number.isInteger(rounded)) return `${rounded}x`
  const asOne = Math.round(rounded * 10) / 10
  if (Math.abs(asOne - rounded) < 1e-9) return `${asOne.toFixed(1)}x`
  return `${rounded.toFixed(2)}x`
}

function formatRulerTickLabel(value: number, suffix?: string) {
  if (!suffix) return formatTickLabel(value)
  const rounded = Math.round(value * 100) / 100
  if (Number.isInteger(rounded)) return `${rounded}${suffix}`
  const oneDecimal = Math.round(rounded * 10) / 10
  const formatted = Math.abs(oneDecimal - rounded) < 1e-9 ? oneDecimal.toFixed(1) : rounded.toFixed(2)
  return `${formatted}${suffix}`
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function stepDecimals(step: number) {
  const fraction = String(step).split(".")[1]
  return fraction?.length ?? 0
}

function snapToStep(value: number, min: number, max: number, step: number) {
  const precision = stepDecimals(step)
  const steps = Math.round((value - min) / step)
  const snapped = min + steps * step
  return Number(clamp(snapped, min, max).toFixed(precision))
}

function buildScaleTicks(min: number, max: number, count = SCALE_TICK_COUNT): number[] {
  if (!(max > min) || count < 2) return min === max ? [min] : [min, max]
  const span = max - min
  return Array.from({ length: count }, (_, index) => {
    const raw = min + (span * index) / (count - 1)
    return Math.round(raw * 100) / 100
  })
}

export function ActionLeverageRuler({
  value,
  onChange,
  min = DEFAULT_MIN,
  max = DEFAULT_MAX,
  step = DEFAULT_STEP,
  label = "Multiplier",
  valueSuffix,
  subvalue,
  variant = "embedded",
}: {
  value: string
  onChange: (value: string) => void
  min?: number
  max?: number
  step?: number
  label?: string
  valueSuffix?: string
  subvalue?: string
  /** Spacing only — never wraps in a card. */
  variant?: "card" | "embedded"
}) {
  const { t } = useTranslation()
  const parsed = Number.parseFloat(value)
  const currentValue = Number.isFinite(parsed) ? snapToStep(parsed, min, max, step) : min
  const fillPct = max > min ? clamp(((currentValue - min) / (max - min)) * 100, 0, 100) : 0
  const ticks = useMemo(() => buildScaleTicks(min, max), [min, max])

  const publishValue = useCallback(
    (next: number) => {
      onChange(String(snapToStep(next, min, max, step)))
    },
    [max, min, onChange, step],
  )

  return (
    <div data-testid="action-leverage-ruler">
      <div className="flex items-center justify-between gap-4">
        <div className="text-[15px] font-semibold tracking-[-0.02em] text-foreground">{t(label)}</div>
        <div
          className="rounded-full bg-muted px-3 py-1 font-data text-[14px] font-medium tabular-nums text-foreground"
          aria-live="polite"
          aria-atomic="true"
          data-testid="action-leverage-pill"
        >
          {formatRulerValue(currentValue, valueSuffix)}
        </div>
      </div>

      <div className={cn("relative px-2", variant === "embedded" ? "mt-6" : "mt-7")}>
        <div
          className="pointer-events-none absolute inset-x-2 top-1/2 z-0 h-1.5 -translate-y-1/2 rounded-full bg-border/70"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute left-2 top-1/2 z-[5] h-1.5 -translate-y-1/2 rounded-full bg-brand transition-[width] duration-150 ease-out"
          style={{ width: `calc((100% - 1rem) * ${fillPct / 100})` }}
          aria-hidden
        />
        <Slider
          min={min}
          max={max}
          step={step}
          value={[currentValue]}
          onValueChange={(values) => publishValue(values[0] ?? min)}
          aria-label={t(label)}
          className="relative z-20 h-7 w-full touch-none appearance-none bg-transparent accent-primary [&::-webkit-slider-runnable-track]:h-1.5 [&::-webkit-slider-runnable-track]:rounded-full [&::-webkit-slider-runnable-track]:bg-transparent [&::-webkit-slider-thumb]:-mt-2 [&::-webkit-slider-thumb]:h-6 [&::-webkit-slider-thumb]:w-6 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:border-[3px] [&::-webkit-slider-thumb]:border-background [&::-webkit-slider-thumb]:bg-brand [&::-webkit-slider-thumb]:shadow-elev-2 [&::-webkit-slider-thumb]:ring-2 [&::-webkit-slider-thumb]:ring-brand [&::-moz-range-track]:h-1.5 [&::-moz-range-track]:rounded-full [&::-moz-range-track]:bg-transparent [&::-moz-range-thumb]:h-6 [&::-moz-range-thumb]:w-6 [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:border-[3px] [&::-moz-range-thumb]:border-background [&::-moz-range-thumb]:bg-brand [&::-moz-range-thumb]:shadow-elev-2"
        />
      </div>

      <div
        className="mt-3 grid px-1 font-data text-[12px] font-medium text-muted-foreground"
        style={{ gridTemplateColumns: `repeat(${ticks.length}, minmax(0, 1fr))` }}
        data-testid="action-leverage-ticks"
      >
        {ticks.map((tick, index) => (
          <span
            key={`${tick}-${index}`}
            className={cn(
              "tabular-nums",
              index === 0 ? "text-left" : index === ticks.length - 1 ? "text-right" : "text-center",
            )}
          >
            {formatRulerTickLabel(tick, valueSuffix)}
          </span>
        ))}
      </div>

      {subvalue ? (
        <div className="mt-4 text-right text-[14px] tabular-nums text-muted-foreground" aria-live="polite">
          {subvalue}
        </div>
      ) : null}
    </div>
  )
}
