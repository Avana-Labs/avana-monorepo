/** One Liquidation Risk stat of a pool detail page, as services/convex sends it (`lib/riskViews.ts`). */
export type LiquidationRiskStat = {
  id: string
  label: string
  value: string
  /** Absolute day-over-day change (latest − previous). Sign drives ▲/▼. */
  deltaValue: number
  /** Pre-formatted absolute delta label without sign (UI adds ▲/▼). */
  deltaLabel: string
  /** For risk metrics, down is good. */
  goodDirection: "up" | "down"
  format: "usd" | "number"
}
