import { cn } from "@/lib/utils"

type CapacityFilledProps = {
  value?: number | null
  className?: string
  /** `sm` fits a 20px mobile stat row, so the Capacity Filled row is as tall as its neighbours. */
  size?: "md" | "sm"
}

/** Whole percent, except a value above 0 and under 1, which keeps two decimals so it never reads as 0%. */
export function formatCapacityFilled(percentage: number): string {
  if (percentage > 0 && percentage < 0.01) return "<0.01%"
  if (percentage > 0 && percentage < 1) return `${percentage.toFixed(2)}%`
  return `${Math.round(percentage)}%`
}

/** Compact utilization gauge shared by the market tables. `value` is a percentage (0–100). */
export function CapacityFilled({ value, className, size = "md" }: CapacityFilledProps) {
  const hasValue = typeof value === "number" && Number.isFinite(value)
  const percentage = hasValue ? Math.min(100, Math.max(0, value)) : null
  const label = percentage === null ? null : formatCapacityFilled(percentage)
  const circumference = 2 * Math.PI * 12

  return (
    <div
      role="img"
      aria-label={label === null ? "Capacity filled unavailable" : `Capacity filled ${label}`}
      className={cn(
        "inline-flex items-center whitespace-nowrap",
        size === "sm" ? "gap-2 align-top leading-5" : "gap-2.5",
        className,
      )}
    >
      <svg
        aria-hidden="true"
        viewBox="0 0 32 32"
        className={cn("shrink-0 -rotate-90", size === "sm" ? "size-5" : "size-8")}
      >
        <circle
          cx="16"
          cy="16"
          r="12"
          fill="none"
          stroke="currentColor"
          strokeWidth="4"
          className="text-border dark:text-white/10"
        />
        {percentage !== null ? (
          <circle
            cx="16"
            cy="16"
            r="12"
            fill="none"
            stroke="#01AACF"
            strokeWidth="4"
            strokeLinecap="round"
            strokeDasharray={circumference}
            strokeDashoffset={circumference * (1 - percentage / 100)}
          />
        ) : null}
      </svg>
      <span className="font-data text-[15px] font-normal tabular-nums text-foreground dark:text-white">
        {label ?? "—"}
      </span>
    </div>
  )
}
