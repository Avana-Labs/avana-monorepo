"use client"

import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { formatPercent } from "@/app/lib/format"
import { formatHealthFactor } from "@/app/lib/data/borrow-domain"
import { RiskLevelPill, SectionCard } from "@/app/borrow/_detail/ui"
import { ActionCard, ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { TokenIcon } from "@/app/components/token-icon"
import type { RiskLevel as DetailRiskLevel } from "@/app/lib/borrow-detail"
import type { ActionMetricRow, ActionMetricTone } from "@/app/lib/action-system/contracts"
import type { AskAiRun } from "@/convex/lib/askAI/modeRun"
import type { AskAiAction, AskAiWidget } from "@/convex/lib/askAI/widgets"
import type { RiskLevel } from "@/convex/lib/askAI/positionContext"

/**
 * Renders a deterministic Ask AI mode-run as native detail-page cards, inline in the
 * chat thread. Every number comes from the run's typed widgets (engine-sourced on one
 * snapshot); this file only formats and lays them out using the app's own components
 * (SectionCard, ActionMetricsBlock, RiskLevelPill, TokenIcon), so the cards look
 * identical to the rest of the app. Unknown values render "—" rather than a fake $0.
 *
 * Copy is routed through `t(COPY.x)` (dynamic) so it translates when a key exists and
 * stays clear of the literal-key parity gate until the translation backfill.
 */

// User-facing strings. Kept as data so `t(COPY.x)` is a dynamic (non-literal) call.
const COPY = {
  positionRisk: "Position risk",
  borrowCapacity: "Borrow capacity",
  collateralBreakdown: "Collateral breakdown",
  liquidationBoundary: "Liquidation boundary",
  netCarry: "Net carry",
  feesVsInterest: "Fees vs interest per day",
  priceShockScenarios: "Price-shock scenarios",
  comparableLps: "Comparable LPs",
  suggestedActions: "Suggested actions",
  assumptions: "Assumptions",
  healthFactor: "Health factor",
  liquidationBuffer: "Liquidation buffer",
  currentLtv: "Current LTV",
  liqThreshold: "Liq. threshold",
  availableNow: "Available now",
  maxBorrow: "Max borrow",
  borrowableAtHf: "Borrowable @ HF",
  perDay: "Per day",
  sevenDay: "7-day",
  thirtyDay: "30-day",
  lpFees: "LP fees",
  interest: "Interest",
  asset: "Asset",
  weight: "Weight",
  value: "Value",
  feeApr: "7d fee APR",
  range: "Range",
  inRange: "in range",
  outOfRange: "out of range",
  pool: "Pool",
  borrow: "Borrow",
  netApy: "Net APY",
  safe: "Safe",
  nearLiquidation: "Near liq.",
  liquidated: "Liquidated",
  noLiquidationRisk: "No liquidation risk",
  liquidatesAt: "Liquidates at",
  rankedByNetApy: "ranked by net APY",
  source: "Source",
  feeWindow: "fee window",
  asOf: "as of",
} as const

function toDetailRiskLevel(level: RiskLevel): DetailRiskLevel {
  return level === "critical" ? "high" : level === "elevated" ? "elevated" : "low"
}

function toneFromRisk(level: RiskLevel): ActionMetricTone {
  return level === "critical" ? "danger" : level === "elevated" ? "warning" : "default"
}

export function AskAiRunCards({ run }: { run: AskAiRun }) {
  const { t } = useTranslation()
  const cur = useCurrency()

  const money = (value: number | null | undefined) => (value == null ? "—" : cur.exact(value))
  // Values already expressed as percentages (e.g. 65 → "65.00%").
  const pct = (value: number | null | undefined) => (value == null ? "—" : formatPercent(value))
  // Ratios (e.g. 0.4) shown as percentages.
  const ratioPct = (value: number | null | undefined) => (value == null ? "—" : formatPercent(value * 100))
  const hf = (value: number | null) => (value === null ? "∞" : formatHealthFactor(value))

  return (
    <div className="flex w-full flex-col gap-4" data-testid="ask-ai-run-cards" data-mode={run.mode}>
      {run.narrative ? <p className="text-sm text-foreground">{run.narrative}</p> : null}
      {run.widgets.map((widget, index) => (
        <Widget
          key={`${widget.type}-${index}`}
          widget={widget}
          t={t}
          money={money}
          pct={pct}
          ratioPct={ratioPct}
          hf={hf}
        />
      ))}
      {run.actions.length > 0 ? <ActionsCard actions={run.actions} t={t} hf={hf} /> : null}
    </div>
  )
}

type Fmt = {
  t: (key: string) => string
  money: (v: number | null | undefined) => string
  pct: (v: number | null | undefined) => string
  ratioPct: (v: number | null | undefined) => string
  hf: (v: number | null) => string
}

function Widget({ widget, ...fmt }: { widget: AskAiWidget } & Fmt) {
  const { t, money, pct, ratioPct, hf } = fmt
  switch (widget.type) {
    case "risk_summary": {
      const rows: ActionMetricRow[] = [
        { id: "health-factor", label: COPY.healthFactor, value: hf(widget.healthFactor) },
        {
          id: "liquidation-buffer",
          label: COPY.liquidationBuffer,
          value: pct(widget.bufferPct),
          tone: toneFromRisk(widget.riskLevel),
        },
        { id: "current-ltv", label: COPY.currentLtv, value: ratioPct(widget.currentLtv) },
      ]
      return (
        <SectionCard
          title={t(COPY.positionRisk)}
          chrome="plain"
          bodyClassName="p-0"
          rightSlot={<RiskLevelPill level={toDetailRiskLevel(widget.riskLevel)} size="md" />}
        >
          <ActionMetricsBlock rows={rows} />
        </SectionCard>
      )
    }
    case "borrow_capacity": {
      const c = widget.capacity
      const rows: ActionMetricRow[] = [
        { id: "available-now", label: COPY.availableNow, value: money(c.availableUsd) },
        { id: "max-borrow", label: COPY.maxBorrow, value: money(c.maxDebtUsd) },
        ...c.atHfTargets.map((target) => ({
          id: `hf-target-${target.healthFactor}`,
          label: `${t(COPY.borrowableAtHf)} ${target.healthFactor.toFixed(1)}`,
          value: money(target.borrowableUsd),
        })),
      ]
      return (
        <SectionCard title={t(COPY.borrowCapacity)} chrome="plain" bodyClassName="p-0">
          <ActionMetricsBlock rows={rows} />
        </SectionCard>
      )
    }
    case "collateral_breakdown":
      if (widget.legs.length === 0) return null
      return (
        <SectionCard title={t(COPY.collateralBreakdown)}>
          <div className="overflow-x-auto">
            <table className="w-full border-collapse text-left text-sm">
              <thead className="text-xs text-muted-foreground">
                <tr>
                  <th className="py-1.5 pr-3 font-medium">{t(COPY.asset)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.weight)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.value)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.feeApr)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.range)}</th>
                </tr>
              </thead>
              <tbody>
                {widget.legs.map((leg) => (
                  <tr key={leg.symbol} className="border-t border-border/60">
                    <td className="py-2 pr-3">
                      <span className="inline-flex items-center gap-2">
                        <TokenIcon symbol={leg.symbol} size="sm" />
                        <span className="font-medium">{leg.symbol}</span>
                      </span>
                    </td>
                    <td className="px-3 py-2 tabular-nums">{ratioPct(leg.weight)}</td>
                    <td className="px-3 py-2 tabular-nums">{money(leg.valueUsd)}</td>
                    <td className="px-3 py-2 tabular-nums">{pct(leg.feeApr7dPct)}</td>
                    <td className="px-3 py-2">
                      {leg.inRange == null ? (
                        "—"
                      ) : (
                        <span
                          className={cn(
                            "inline-flex items-center gap-1.5",
                            leg.inRange ? "text-success" : "text-danger",
                          )}
                        >
                          <span className={cn("size-1.5 rounded-full", leg.inRange ? "bg-success" : "bg-danger")} />
                          {leg.inRange ? t(COPY.inRange) : t(COPY.outOfRange)}
                        </span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </SectionCard>
      )
    case "liquidation_boundary": {
      const liq = widget.boundary.liquidationPriceShockPct
      return (
        <SectionCard
          title={t(COPY.liquidationBoundary)}
          rightSlot={
            <span className="text-xs text-muted-foreground tabular-nums">
              {liq == null ? t(COPY.noLiquidationRisk) : `${t(COPY.liquidatesAt)} ${formatPercent(liq)}`}
            </span>
          }
        >
          <BoundaryChart points={widget.boundary.points} liquidationShockPct={liq} />
        </SectionCard>
      )
    }
    case "carry_summary": {
      const c = widget.carry
      if (c.netCarryPerDayUsd == null && c.projected7dUsd == null && c.projected30dUsd == null) return null
      const rows: ActionMetricRow[] = [
        {
          id: "net-per-day",
          label: COPY.perDay,
          value: money(c.netCarryPerDayUsd),
          tone: c.netCarryPerDayUsd == null ? "default" : c.netCarryPerDayUsd >= 0 ? "positive" : "danger",
        },
        { id: "net-7-day", label: COPY.sevenDay, value: money(c.projected7dUsd) },
        { id: "net-30-day", label: COPY.thirtyDay, value: money(c.projected30dUsd) },
      ]
      return (
        <SectionCard title={t(COPY.netCarry)} chrome="plain" bodyClassName="p-0">
          <ActionMetricsBlock rows={rows} />
        </SectionCard>
      )
    }
    case "fee_vs_interest":
      if (widget.feePerDayUsd == null && widget.interestPerDayUsd == null) return null
      return (
        <SectionCard title={t(COPY.feesVsInterest)}>
          <FeeVsInterestBars
            feePerDayUsd={widget.feePerDayUsd}
            interestPerDayUsd={widget.interestPerDayUsd}
            money={money}
            feeLabel={t(COPY.lpFees)}
            interestLabel={t(COPY.interest)}
          />
        </SectionCard>
      )
    case "stress_tiles":
      return (
        <SectionCard title={t(COPY.priceShockScenarios)}>
          <div className="grid grid-cols-3 gap-2">
            {widget.presets.map((preset) => {
              const state = preset.liquidated
                ? "bad"
                : preset.healthFactor != null && preset.healthFactor < 1.5
                  ? "warn"
                  : "ok"
              return (
                <div key={preset.priceShockPct} className="rounded-radius-md border border-border p-3 text-center">
                  <div className="text-[11px] font-semibold text-muted-foreground tabular-nums">
                    {formatPercent(preset.priceShockPct)}
                  </div>
                  <div className="my-1 text-lg font-bold tabular-nums">{hf(preset.healthFactor)}</div>
                  <StressPill state={state} t={t} />
                </div>
              )
            })}
          </div>
        </SectionCard>
      )
    case "comparable_lp":
      return (
        <SectionCard
          title={t(COPY.comparableLps)}
          rightSlot={<span className="text-xs text-muted-foreground">{t(COPY.rankedByNetApy)}</span>}
        >
          <div className="overflow-x-auto">
            <table className="w-full border-collapse text-left text-sm">
              <thead className="text-xs text-muted-foreground">
                <tr>
                  <th className="py-1.5 pr-3 font-medium">{t(COPY.pool)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.feeApr)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.borrow)}</th>
                  <th className="px-3 py-1.5 font-medium">{t(COPY.netApy)}</th>
                </tr>
              </thead>
              <tbody>
                {widget.rows.map((row) => (
                  <tr key={row.id} className="border-t border-border/60">
                    <td className="py-2 pr-3 font-medium">{row.label}</td>
                    <td className="px-3 py-2 tabular-nums">{pct(row.feeApr7dPct)}</td>
                    <td className="px-3 py-2 tabular-nums">{pct(row.borrowApyPct ?? 0)}</td>
                    <td className="px-3 py-2 font-medium tabular-nums">{pct(row.netApyPct)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </SectionCard>
      )
    case "assumptions":
      return (
        <p className="text-xs text-muted-foreground tabular-nums">
          <span className="font-medium text-foreground">{t(COPY.assumptions)}</span> · {widget.snapshotId} ·{" "}
          {t(COPY.asOf)} {new Date(widget.asOf).toLocaleString()} · {t(COPY.liqThreshold)}{" "}
          {formatPercent(widget.liquidationThresholdPct)} · {t(COPY.feeWindow)} {widget.feeWindowDays}d ·{" "}
          {t(COPY.source)}: {widget.provenance}
        </p>
      )
    default:
      return null
  }
}

function StressPill({ state, t }: { state: "ok" | "warn" | "bad"; t: (k: string) => string }) {
  const cls =
    state === "bad"
      ? "bg-danger/10 text-danger"
      : state === "warn"
        ? "bg-warning/10 text-warning"
        : "bg-success/10 text-success"
  const label = state === "bad" ? COPY.liquidated : state === "warn" ? COPY.nearLiquidation : COPY.safe
  return <span className={cn("inline-flex rounded-xs px-1.5 py-0.5 text-[10px] font-medium", cls)}>{t(label)}</span>
}

function FeeVsInterestBars({
  feePerDayUsd,
  interestPerDayUsd,
  money,
  feeLabel,
  interestLabel,
}: {
  feePerDayUsd: number | null
  interestPerDayUsd: number | null
  money: (v: number | null | undefined) => string
  feeLabel: string
  interestLabel: string
}) {
  const max = Math.max(feePerDayUsd ?? 0, interestPerDayUsd ?? 0, 1e-9)
  const width = (v: number | null) => (v == null ? 0 : Math.max(0, (v / max) * 100))
  return (
    <div className="flex flex-col gap-2.5 text-sm">
      <Bar label={feeLabel} value={money(feePerDayUsd)} widthPct={width(feePerDayUsd)} fillClass="bg-success" />
      <Bar
        label={interestLabel}
        value={money(interestPerDayUsd)}
        widthPct={width(interestPerDayUsd)}
        fillClass="bg-danger"
      />
    </div>
  )
}

function Bar({
  label,
  value,
  widthPct,
  fillClass,
}: {
  label: string
  value: string
  widthPct: number
  fillClass: string
}) {
  return (
    <div className="flex items-center gap-3">
      <span className="w-20 shrink-0 text-muted-foreground">{label}</span>
      <span className="h-4 flex-1 overflow-hidden rounded-xs bg-muted">
        <span className={cn("block h-full rounded-xs", fillClass)} style={{ width: `${widthPct}%` }} />
      </span>
      <span className="w-16 shrink-0 text-right font-medium tabular-nums">{value}</span>
    </div>
  )
}

function BoundaryChart({
  points,
  liquidationShockPct,
}: {
  points: { priceShockPct: number; healthFactor: number | null }[]
  liquidationShockPct: number | null
}) {
  const finite = points.filter((p): p is { priceShockPct: number; healthFactor: number } => p.healthFactor !== null)
  if (finite.length < 2) return <p className="text-xs text-muted-foreground">—</p>
  const W = 320
  const H = 84
  const shocks = finite.map((p) => p.priceShockPct)
  const hfs = finite.map((p) => p.healthFactor)
  const minShock = Math.min(...shocks)
  const maxShock = Math.max(...shocks)
  const minHf = Math.min(...hfs, 1)
  const maxHf = Math.max(...hfs, 1)
  const x = (s: number) => (maxShock === minShock ? 0 : ((s - maxShock) / (minShock - maxShock)) * W)
  const y = (h: number) => (maxHf === minHf ? H / 2 : H - ((h - minHf) / (maxHf - minHf)) * (H - 8) - 4)
  const line = finite.map((p) => `${x(p.priceShockPct).toFixed(1)},${y(p.healthFactor).toFixed(1)}`).join(" ")
  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      width="100%"
      height={H}
      role="img"
      aria-label="Health factor versus collateral price change"
    >
      <line x1={0} y1={y(1)} x2={W} y2={y(1)} className="stroke-danger" strokeDasharray="3 3" strokeWidth={1} />
      <polyline points={line} fill="none" className="stroke-accent-foreground" strokeWidth={2} />
      {liquidationShockPct != null && liquidationShockPct >= minShock && liquidationShockPct <= maxShock ? (
        <circle cx={x(liquidationShockPct)} cy={y(1)} r={3.5} className="fill-danger" />
      ) : null}
    </svg>
  )
}

function ActionsCard({
  actions,
  t,
  hf,
}: {
  actions: AskAiAction[]
  t: (k: string) => string
  hf: (v: number | null) => string
}) {
  return (
    <SectionCard title={t(COPY.suggestedActions)}>
      <ActionCard className="divide-y divide-border/80 overflow-hidden">
        {actions.map((action) => (
          <div key={action.id} className="flex items-start justify-between gap-3 px-4 py-3">
            <div>
              <div className="text-sm font-medium">{action.label}</div>
              <div className="text-xs text-muted-foreground">{action.rationale}</div>
            </div>
            {action.resultingHealthFactor != null ? (
              <span className="shrink-0 text-xs text-muted-foreground tabular-nums">
                → {hf(action.resultingHealthFactor)}
              </span>
            ) : null}
          </div>
        ))}
      </ActionCard>
    </SectionCard>
  )
}
