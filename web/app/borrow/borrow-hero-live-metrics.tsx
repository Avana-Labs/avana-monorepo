"use client"

import { HowItWorks } from "@/app/components/how-it-works"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type BorrowHeroMetrics = {
  totalTvlUsd: number
  totalCollateralUsd: number
  availableCreditUsd: number
  outstandingLoansUsd: number
  totalTvlChangePct: number
}

function MetricsView({ metrics }: { metrics: BorrowHeroMetrics }) {
  const fc = useCurrency()
  const { t } = useTranslation()
  return (
    <div className="pb-4">
      <div className="flex w-full items-start justify-between gap-4">
        <div className="min-w-0 space-y-1.5">
          <p className="text-[13px] text-muted-foreground">{t("Borrow TVL")}</p>
          <p className="flex flex-wrap items-center gap-x-2 gap-y-1 font-data text-[17px] font-medium leading-none tracking-normal tabular-nums text-foreground md:text-[18px]">
            {fc.compact(metrics.totalTvlUsd)}
          </p>
        </div>

        <div className="hidden md:ml-auto md:flex md:gap-8 md:text-right">
          <div className="min-w-0 space-y-1.5">
            <p className="flex items-center justify-end gap-1.5 text-[13px] text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
              {t("Available Credit")}
            </p>
            <p className="font-data text-[17px] md:text-[18px] font-medium leading-none tracking-normal tabular-nums text-foreground">
              {fc.compact(metrics.availableCreditUsd)}
            </p>
          </div>

          <div className="min-w-0 space-y-1.5">
            <p className="flex items-center justify-end gap-1.5 text-[13px] text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
              {t("Outstanding Loans")}
            </p>
            <p className="font-data text-[17px] md:text-[18px] font-medium leading-none tracking-normal tabular-nums text-foreground">
              {fc.compact(metrics.outstandingLoansUsd)}
            </p>
          </div>
        </div>

        <HowItWorks topic="borrow" className="self-center md:hidden" />
      </div>

      {/* Mobile only: the two figures shown inline on desktop are hidden below md, so surface a
      condensed row that keeps all three numbers present at phone width. */}
      <div className="mt-3 grid grid-cols-2 gap-4 md:hidden">
        <div className="min-w-0 space-y-1">
          <p className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
            {t("Available Credit")}
          </p>
          <p className="font-data text-[15px] font-medium leading-none tabular-nums text-foreground">
            {fc.compact(metrics.availableCreditUsd)}
          </p>
        </div>
        <div className="min-w-0 space-y-1">
          <p className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
            {t("Outstanding Loans")}
          </p>
          <p className="font-data text-[15px] font-medium leading-none tabular-nums text-foreground">
            {fc.compact(metrics.outstandingLoansUsd)}
          </p>
        </div>
      </div>
    </div>
  )
}

/**
 * Borrow hero headline metrics. The caller owns which page-data snapshot is
 * current (server fallback vs session-backed client refresh), so this stays a
 * pure view over one consistent metrics object.
 */
export function BorrowHeroLiveMetrics({ metrics }: { metrics: BorrowHeroMetrics }) {
  return <MetricsView metrics={metrics} />
}
