/**
 * Maps liquidation utilization (borrowed ÷ liq. max, as a 0–100 percentage) to tone
 * classes for the borrowing-power bar and "% of liq. max" label. Healthy positions
 * stay green; tone escalates as utilization approaches liquidation.
 */
export function liqUtilizationPercentTextClass(pct: number): string {
  if (!Number.isFinite(pct) || pct < 50) return "text-success"
  if (pct < 75) return "text-amber-600 dark:text-amber-400"
  if (pct < 90) return "text-orange-600 dark:text-orange-400"
  return "text-rose-500"
}

export function liqUtilizationBarClass(pct: number): string {
  if (!Number.isFinite(pct) || pct < 50) return "bg-emerald-500"
  if (pct < 75) return "bg-amber-400"
  if (pct < 90) return "bg-orange-500"
  return "bg-rose-500"
}
