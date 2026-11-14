"use client"

import * as React from "react"
import type { RiskAssessment } from "@/app/lib/borrow-detail"
import { formatBpsAsPct, riskLevelLabel } from "@/app/lib/borrow-detail"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  RiskGauge,
  RiskLevelPill,
  SectionCard,
  SectionCardCopy,
  SectionCardPrimaryMetric,
  SectionCardSupportingLabel,
} from "../ui"
import { DeltaPill } from "@/app/components/ui/live/delta-pill"
import { cn } from "@/lib/utils"

type Props = { detail: { risk: RiskAssessment } }

export function RiskSection({ detail }: Props) {
  const { risk } = detail
  const { t } = useTranslation()
  const [expanded, setExpanded] = React.useState<Set<string>>(new Set())
  const toggle = (id: string) =>
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  const metricByLabel = React.useMemo(() => {
    const map: Record<string, string> = {}
    for (const m of risk.metrics) map[m.label.toLowerCase()] = m.value
    return map
  }, [risk.metrics])

  return (
    <SectionCard
      title={t("Risk premium")}
      rightSlot={<RiskLevelPill level={risk.level} size="md" />}
      chrome="plain"
      bodyClassName="p-0"
    >
      <div className="space-y-6">
        <div className="flex flex-wrap items-center justify-between gap-6">
          <div className="min-w-0">
            <div className="flex items-baseline gap-2">
              <SectionCardPrimaryMetric>{formatBpsAsPct(risk.premiumBps)}</SectionCardPrimaryMetric>
              <SectionCardSupportingLabel>({risk.premiumBps} bps)</SectionCardSupportingLabel>
            </div>
          </div>
          <div className="flex flex-col items-center">
            <RiskGauge
              score={risk.score}
              level={risk.level}
              label={t("{level} risk").replace("{level}", t(riskLevelLabel(risk.level)))}
              size={140}
            />
            {risk.lastReviewed ? (
              <SectionCardSupportingLabel className="mt-1 text-[11px]">
                {t("Last reviewed {date}").replace("{date}", risk.lastReviewed)}
              </SectionCardSupportingLabel>
            ) : null}
          </div>
        </div>

        <div>
          <ul className="space-y-2">
            {risk.breakdown.map((item) => {
              const open = expanded.has(item.id)
              const relatedMetric = metricByLabel[item.label.toLowerCase()]
              return (
                <li
                  key={item.id}
                  className="rounded-radius-md border border-border/70 bg-background/45 transition-colors hover:border-border hover:bg-hover/40"
                >
                  <button
                    type="button"
                    aria-expanded={open}
                    onClick={() => toggle(item.id)}
                    className="flex w-full items-start justify-between gap-4 px-4 py-3 text-left"
                  >
                    <div className="min-w-0">
                      <div className="flex min-w-0 flex-wrap items-center gap-2">
                        <span
                          className={cn(
                            "truncate text-[15px] font-normal tracking-[-0.02em] transition-colors",
                            open ? "text-foreground" : "text-muted-foreground",
                          )}
                        >
                          {t(item.label)}
                        </span>
                        <RiskLevelPill level={item.level} size="sm" />
                      </div>
                      {open ? (
                        <SectionCardCopy className="mt-2 max-w-[560px] text-[13px] leading-5">
                          {t(item.description)}
                        </SectionCardCopy>
                      ) : null}
                    </div>
                    <div className="flex shrink-0 items-center gap-2">
                      {relatedMetric ? (
                        <span className="hidden font-data text-[12px] tabular-nums text-muted-foreground sm:inline">
                          {relatedMetric}
                        </span>
                      ) : null}
                      <DeltaPill value={item.bps / 100} format="percent" digits={2} hideZero={false} />
                      <svg
                        width="12"
                        height="12"
                        viewBox="0 0 14 14"
                        aria-hidden
                        className={
                          open
                            ? "rotate-180 text-muted-foreground transition-transform"
                            : "text-muted-foreground transition-transform"
                        }
                      >
                        <path
                          d="M3 5 L7 9 L11 5"
                          fill="none"
                          stroke="currentColor"
                          strokeWidth={1.5}
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        />
                      </svg>
                    </div>
                  </button>
                </li>
              )
            })}
          </ul>
        </div>
      </div>
    </SectionCard>
  )
}
