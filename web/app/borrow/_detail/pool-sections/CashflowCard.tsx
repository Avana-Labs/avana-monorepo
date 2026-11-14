"use client"

import { cn } from "@/lib/utils"
import type { CashflowCard as CashflowCardData } from "@/app/lib/borrow-detail"
import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { SectionCard } from "../ui"

// Structural prop (like QuickStatsGrid / RiskSection) so any detail view-model
// carrying a `cashflow: CashflowCard` (borrow pool, lend market) can reuse this.
type Props = {
  detail: { cashflow: CashflowCardData }
}

function parseCompactUsd(value: string) {
  const match = value.replace(/,/g, "").match(/-?\d+(?:\.\d+)?/)
  if (!match) return null
  const number = Number(match[0])
  if (!Number.isFinite(number)) return null
  const suffix = value
    .trim()
    .match(/[KMB]$/i)?.[0]
    ?.toUpperCase()
  const multiplier = suffix === "B" ? 1_000_000_000 : suffix === "M" ? 1_000_000 : suffix === "K" ? 1_000 : 1
  return number * multiplier
}

function periodValue(reported: string, days: 1 | 30 | 90) {
  const parsed = parseCompactUsd(reported)
  if (parsed == null) return "—"
  return formatCompactUsd((parsed / 90) * days)
}

export function CashflowCard({ detail }: Props) {
  // The server has already merged the preload into this card. Keeping that
  // snapshot avoids replacing every cashflow number after hydration.
  return <CashflowCardView detail={detail} />
}

function CashflowCardView({ detail }: { detail: Props["detail"] }) {
  const { cashflow } = detail
  const { t } = useTranslation()

  return (
    <SectionCard title={t("Cashflow breakdown")} chrome="plain" bodyClassName="p-0">
      <div className="overflow-x-auto">
        <table className="w-full table-fixed text-[13px]">
          <colgroup>
            <col className="w-[40%]" />
            <col className="w-[20%]" />
            <col className="w-[20%]" />
            <col className="w-[20%]" />
          </colgroup>
          <thead>
            <tr className="border-b border-border text-left text-[11px] font-medium uppercase tracking-[0.06em] text-muted-foreground">
              <th className="pb-2 pt-3">{t("Line")}</th>
              <th className="pb-2 pt-3 text-right">{t("1D")}</th>
              <th className="pb-2 pt-3 text-right">{t("30 Days")}</th>
              <th className="pb-2 pt-3 text-right">{t("90 Days")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {cashflow.rows.map((row, i) => (
              <tr
                key={i}
                className={cn("transition-colors hover:bg-hover", row.highlighted ? "bg-surface-inset/40" : undefined)}
              >
                <th scope="row" className="py-2.5 text-left text-[14px] font-normal text-muted-foreground">
                  {t(row.label)}
                </th>
                <td
                  className={cn(
                    "py-2.5 text-right font-data font-medium tabular-nums",
                    row.highlighted ? "text-foreground" : "text-muted-foreground",
                  )}
                >
                  {periodValue(row.reported, 1)}
                </td>
                <td
                  className={cn(
                    "py-2.5 text-right font-data font-medium tabular-nums",
                    row.highlighted ? "text-foreground" : "text-muted-foreground",
                  )}
                >
                  {periodValue(row.reported, 30)}
                </td>
                <td
                  className={cn(
                    "py-2.5 text-right font-data font-medium tabular-nums",
                    row.highlighted ? "text-foreground" : "text-muted-foreground",
                  )}
                >
                  {periodValue(row.reported, 90)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </SectionCard>
  )
}
