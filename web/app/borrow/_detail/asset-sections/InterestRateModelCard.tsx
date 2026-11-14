"use client"

import * as React from "react"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { InterestRateModelChart } from "@/app/borrow/_detail/asset-sections/InterestRateModelChart"
import type { AssetDetail } from "@/app/lib/borrow-detail"
import {
  buildBorrowInterestRateCurve,
  probeInterestRateModel,
  resolveMarketLiquidityUsd,
} from "@/app/lib/borrow-detail/interest-rate-curve"
import { resolveBorrowDetailMetricHelp } from "@/app/lib/borrow-detail/metric-help"
import { resolveInterestRateModelParams, type ProtocolParameterRow } from "@/app/lib/borrow-detail/protocol-parameters"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"
import { formatPercent } from "@/app/lib/format"

type Props = {
  utilizationPct: number
  borrowAprPct: number
  protocolParameters: ProtocolParameterRow[]
  /** Outstanding borrows (USD). Used for “borrow amount to reach” on hover. */
  borrowedUsd?: number
  /** Total supplied liquidity (USD). Defaults are derived from utilization when omitted. */
  suppliedUsd?: number
  className?: string
}

function readQuickStatPercent(
  quickStats: ReadonlyArray<{ id: string; value: string }>,
  id: string,
  fallback: number,
): number {
  const raw = quickStats.find((stat) => stat.id === id)?.value ?? ""
  const numeric = Number.parseFloat(raw.replace(/[^0-9.-]/g, ""))
  return Number.isFinite(numeric) ? numeric : fallback
}

function seriesEndValue(series: { points: ReadonlyArray<{ v: number }>; aggregate?: number }): number {
  if (typeof series.aggregate === "number" && Number.isFinite(series.aggregate)) return series.aggregate
  const last = series.points.at(-1)
  return last && Number.isFinite(last.v) ? last.v : 0
}

/** Map a borrowable asset detail into InterestRateModelCard props. */
export function interestRateModelFromAssetDetail(detail: AssetDetail): Omit<Props, "className"> {
  const utilizationPct = detail.interestRateModel
    ? detail.interestRateModel.utilizationPct
    : readQuickStatPercent(detail.quickStats, "utilization", detail.row.utilization)
  const borrowAprPct = detail.interestRateModel
    ? detail.interestRateModel.borrowAprPct
    : readQuickStatPercent(detail.quickStats, "borrowApy", detail.row.borrowApr)

  const fromSeriesBorrowed = seriesEndValue(detail.supplyBorrow.borrowed)
  const fromSeriesSupplied = seriesEndValue(detail.supplyBorrow.supplied)
  const borrowedUsd = fromSeriesBorrowed > 0 ? fromSeriesBorrowed : detail.row.totalBorrowedUsd
  const suppliedUsd =
    fromSeriesSupplied > 0
      ? fromSeriesSupplied
      : Math.max(detail.row.totalBorrowedUsd + detail.row.availableUsd, detail.row.totalBorrowedUsd, 1)

  if (detail.interestRateModel) {
    return {
      utilizationPct,
      borrowAprPct,
      borrowedUsd,
      suppliedUsd,
      protocolParameters: [
        {
          id: "optimalUtilization",
          label: "Optimal utilization",
          value: formatPercent(detail.interestRateModel.optimalUtilizationPct),
        },
        {
          id: "slopeBelowOptimal",
          label: "Slope below optimal",
          value: formatPercent(detail.interestRateModel.slopeBelowOptimalPct),
        },
        {
          id: "slopeAboveOptimal",
          label: "Slope above optimal",
          value: formatPercent(detail.interestRateModel.slopeAboveOptimalPct),
        },
        {
          id: "baseBorrowRate",
          label: "Base borrow rate",
          value: formatPercent(detail.interestRateModel.baseBorrowRatePct),
        },
      ],
    }
  }

  return {
    utilizationPct,
    borrowAprPct,
    borrowedUsd,
    suppliedUsd,
    protocolParameters: detail.protocolParameters,
  }
}

export function InterestRateModelCard({
  utilizationPct,
  borrowAprPct,
  protocolParameters,
  borrowedUsd,
  suppliedUsd,
  className,
}: Props) {
  const { t } = useTranslation()
  const currentUtilization = Number.isFinite(utilizationPct) ? utilizationPct : 0
  const currentBorrowApr = Number.isFinite(borrowAprPct) ? borrowAprPct : 4
  const irm = React.useMemo(() => resolveInterestRateModelParams(protocolParameters), [protocolParameters])
  const [hoverUtilization, setHoverUtilization] = React.useState<number | null>(null)

  const helpText = t("Borrow APR rises as utilization increases and steepens past the optimal threshold.")

  const liquidity = React.useMemo(
    () =>
      resolveMarketLiquidityUsd({
        utilizationPct: currentUtilization,
        borrowedUsd,
        suppliedUsd,
      }),
    [borrowedUsd, currentUtilization, suppliedUsd],
  )

  const curve = React.useMemo(
    () => buildBorrowInterestRateCurve(currentUtilization, currentBorrowApr, irm),
    [currentUtilization, currentBorrowApr, irm],
  )

  const anchor = React.useMemo(
    () => ({ utilization: currentUtilization, apr: Math.max(0, currentBorrowApr) }),
    [currentBorrowApr, currentUtilization],
  )

  const probe = React.useMemo(() => {
    if (hoverUtilization == null) return null
    return probeInterestRateModel({
      utilizationPct: hoverUtilization,
      irm,
      anchor,
      borrowedUsd: liquidity.borrowedUsd,
      suppliedUsd: liquidity.suppliedUsd,
    })
  }, [anchor, hoverUtilization, irm, liquidity.borrowedUsd, liquidity.suppliedUsd])

  const paramRows = [
    {
      id: "optimalUtilization",
      label: "Optimal utilization",
      value: formatPercent(irm.optimalUtilizationPct),
    },
    {
      id: "slopeBelowOptimal",
      label: "Slope below optimal",
      value: formatPercent(irm.slopeBelowOptimalPct),
    },
    {
      id: "slopeAboveOptimal",
      label: "Slope above optimal",
      value: formatPercent(irm.slopeAboveOptimalPct),
    },
    {
      // Base rate is read off the anchored curve (its 0%-utilization value) so the
      // displayed base rate is consistent with the plotted curve + "Current" marker,
      // rather than the slug-hashed param that has no relation to the paid APR.
      id: "baseBorrowRate",
      label: "Base borrow rate",
      value: formatPercent(curve.baseApr),
    },
  ] as const

  const utilizationHelp = resolveBorrowDetailMetricHelp("Utilisation rate")

  return (
    <section className={cn("min-w-0", className)} aria-label={t("Interest rate model")}>
      <div className="flex items-center gap-1.5">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
          {t("Interest rate model")}
        </h2>
        <ActionMetricHelp text={helpText} topic="Interest rate model" />
      </div>

      <div className="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1.35fr)_minmax(240px,0.85fr)] lg:items-stretch lg:gap-10">
        <InterestRateModelChart
          curve={curve}
          currentUtilization={currentUtilization}
          probe={probe}
          onProbeUtilization={setHoverUtilization}
        />

        <aside className="flex min-w-0 flex-col justify-center lg:pl-2">
          <div>
            <div className="flex items-center gap-1">
              <span className="text-[13px] font-normal leading-snug text-muted-foreground">
                {t("Utilization rate")}
              </span>
              {utilizationHelp ? <ActionMetricHelp text={utilizationHelp} topic="Utilization rate" /> : null}
            </div>
            <div className="mt-2 font-data text-[28px] font-normal leading-none tracking-[-0.01em] text-foreground md:text-[32px]">
              {formatPercent(currentUtilization)}
            </div>
          </div>

          <div className="mt-6 border-t border-border pt-5 dark:border-white/10">
            <ul className="space-y-4">
              {paramRows.map((row) => {
                const tooltip = resolveBorrowDetailMetricHelp(row.label)
                return (
                  <li key={row.id} className="flex items-start justify-between gap-4">
                    <div className="flex min-w-0 items-center gap-1">
                      <span className="text-[13px] font-normal leading-snug text-muted-foreground">{t(row.label)}</span>
                      {tooltip ? <ActionMetricHelp text={tooltip} topic={row.label} /> : null}
                    </div>
                    <span className="shrink-0 font-data text-[14px] font-medium tabular-nums text-foreground">
                      {row.value}
                    </span>
                  </li>
                )
              })}
            </ul>
          </div>
        </aside>
      </div>
    </section>
  )
}
