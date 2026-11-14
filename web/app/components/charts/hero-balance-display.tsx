import type { ReactNode } from "react"
import { cn } from "@/lib/utils"
import { HeroAnimatedNumber } from "./hero-animated-number"

type HeroBalanceDisplayProps = {
  value: string
  delta: string
  deltaTone?: "positive" | "negative"
  /** Muted text shown after the delta (e.g. a date). */
  meta?: string
  hidden?: boolean
  /** Small uppercase metric label shown above the value (e.g. "Total borrows"). */
  label?: string
  /** Inline node rendered right next to the value (e.g. a show/hide toggle or an info tooltip). */
  valueSuffix?: ReactNode
  /** Optional node rendered under the delta (e.g. an "Assets · Debt" breakdown). Masked when hidden. */
  subtitle?: ReactNode
  variant?: "default" | "strong" | "quiet"
  className?: string
  /**
   * When set with `formatValue`, the headline springs toward this number
   * (Uniswap-style scrub). `value` remains the a11y / fallback string.
   */
  numericValue?: number
  formatValue?: (value: number) => string
  /** Optional spring for the absolute delta amount (e.g. $116.62). */
  numericDeltaAbs?: number
  formatDeltaAbs?: (value: number) => string
  /** Optional spring for the percent portion (e.g. 4.89). */
  numericDeltaPct?: number
  formatDeltaPct?: (value: number) => string
}

function HeroDeltaText({
  value,
  tone,
  meta,
  variant = "default",
  numericDeltaAbs,
  formatDeltaAbs,
  numericDeltaPct,
  formatDeltaPct,
}: {
  value: string
  tone: "positive" | "negative"
  meta?: string
  variant?: "default" | "strong" | "quiet"
  numericDeltaAbs?: number
  formatDeltaAbs?: (value: number) => string
  numericDeltaPct?: number
  formatDeltaPct?: (value: number) => string
}) {
  const useAnimatedDelta =
    numericDeltaAbs != null && formatDeltaAbs != null && numericDeltaPct != null && formatDeltaPct != null

  return (
    <div className="flex items-center gap-2">
      <div
        className={
          tone === "positive" ? "flex items-center gap-1 text-[#01AACF]" : "flex items-center gap-1 text-rose-500"
        }
      >
        <span
          className={cn(
            "leading-none",
            variant === "strong" ? "text-[12px]" : variant === "quiet" ? "text-[12px]" : "text-[11px]",
          )}
        >
          {tone === "positive" ? "▲" : "▼"}
        </span>
        <span
          className={cn(
            "tabular-nums",
            variant === "strong"
              ? "text-[15px] font-normal"
              : variant === "quiet"
                ? "text-[13px] font-normal lg:text-[14px]"
                : "text-[14px] font-medium",
          )}
        >
          {useAnimatedDelta ? (
            <>
              <HeroAnimatedNumber value={numericDeltaAbs} format={formatDeltaAbs} />
              {" ("}
              <HeroAnimatedNumber value={numericDeltaPct} format={formatDeltaPct} />
              {")"}
            </>
          ) : (
            value
          )}
        </span>
      </div>
      {meta ? <span className="text-[13px] font-normal text-muted-foreground">{meta}</span> : null}
    </div>
  )
}

export function HeroBalanceDisplay({
  value,
  delta,
  deltaTone = "positive",
  meta,
  hidden = false,
  label,
  valueSuffix,
  subtitle,
  variant = "default",
  className,
  numericValue,
  formatValue,
  numericDeltaAbs,
  formatDeltaAbs,
  numericDeltaPct,
  formatDeltaPct,
}: HeroBalanceDisplayProps) {
  const animateValue = !hidden && numericValue != null && formatValue != null

  return (
    <div className={cn("space-y-1.5", className)}>
      {label ? (
        <span className="block text-[11px] font-normal uppercase leading-4 tracking-[0.06em] text-muted-foreground">
          {label}
        </span>
      ) : null}
      <div className="flex items-center gap-2">
        <span
          className={cn(
            "leading-none text-foreground",
            variant === "strong"
              ? "text-[29px] font-normal tracking-[-0.015em] sm:text-[32px] md:text-[34px]"
              : variant === "quiet"
                ? "font-data text-[clamp(1.35rem,1.8vw,1.95rem)] font-normal tracking-[-0.02em]"
                : "text-[26px] font-normal tracking-[-0.015em] sm:text-[28px] md:text-[30px]",
          )}
        >
          {hidden ? (
            "••••••••"
          ) : animateValue ? (
            <HeroAnimatedNumber value={numericValue} format={formatValue} />
          ) : (
            value
          )}
        </span>
        {valueSuffix}
      </div>
      {hidden ? (
        <span className="text-[13px] text-muted-foreground">••••••••</span>
      ) : (
        <HeroDeltaText
          value={delta}
          tone={deltaTone}
          meta={meta}
          variant={variant}
          numericDeltaAbs={numericDeltaAbs}
          formatDeltaAbs={formatDeltaAbs}
          numericDeltaPct={numericDeltaPct}
          formatDeltaPct={formatDeltaPct}
        />
      )}
      {subtitle ? <div className="text-[13px] text-muted-foreground">{hidden ? "••••••••" : subtitle}</div> : null}
    </div>
  )
}

export function resolveDeltaTone(delta: string): "positive" | "negative" {
  return delta.trim().startsWith("-") || delta.includes("-$") ? "negative" : "positive"
}
