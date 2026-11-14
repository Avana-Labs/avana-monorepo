"use client"

import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { HowItWorks } from "@/app/components/how-it-works"
import { TestnetMetricsBadge } from "@/app/components/testnet-metrics-badge"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { MultiplyHeroMetrics } from "@/app/lib/data/providers/multiply"

const HIDDEN = "••••••"

export function MultiplyHero({ metrics }: { metrics: MultiplyHeroMetrics }) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const fc = useCurrency()
  const { t } = useTranslation()

  const stats = [
    { label: t("Avg APY at max leverage"), value: `${(metrics.averageMaxApy * 100).toFixed(2)}%`, sensitive: false },
    { label: t("Avg Max Leverage"), value: `${metrics.averageMaxLeverage.toFixed(2)}x`, sensitive: false },
  ]

  return (
    <section className="mb-4">
      <div className="flex w-full items-start justify-between gap-4 pb-4">
        <div className="min-w-0 space-y-1.5">
          <p className="text-[13px] text-muted-foreground">{t("Multiply TVL")}</p>
          <p className="flex flex-wrap items-center gap-x-2 gap-y-1 font-data text-[17px] font-medium leading-none tracking-normal tabular-nums text-foreground md:text-[18px]">
            {showDollarAmounts ? fc.compact(metrics.totalLiquidityUsd) : HIDDEN}
            <TestnetMetricsBadge label={t("Testnet")} />
          </p>
        </div>

        <div className="hidden md:ml-auto md:flex md:gap-8 md:text-right">
          {stats.map((metric) => (
            <div key={metric.label} className="min-w-0 space-y-1.5">
              <p className="flex items-center justify-end gap-1.5 text-[13px] text-muted-foreground">
                <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground" />
                {metric.label}
              </p>
              <p className="font-data text-[17px] md:text-[18px] font-medium leading-none tracking-normal tabular-nums text-foreground">
                {metric.sensitive && !showDollarAmounts ? HIDDEN : metric.value}
              </p>
            </div>
          ))}
        </div>

        <HowItWorks topic="multiply" className="self-center md:hidden" />
      </div>
    </section>
  )
}
