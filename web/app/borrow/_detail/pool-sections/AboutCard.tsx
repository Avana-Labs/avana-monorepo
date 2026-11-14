"use client"

import * as React from "react"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { ArrowUpRight } from "@/app/components/icons"
import type { AboutCard as AboutCardData } from "@/app/lib/borrow-detail"
import { ABOUT_CONTRACT_ADDRESS_HELP } from "@/app/lib/detail-page/about-contract-addresses"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { SectionCardCopy } from "../ui"

type Props = { about: AboutCardData; title?: string; compact?: boolean; plain?: boolean }

/** Collapsed description length before a "read more" toggle appears. */
const DESCRIPTION_CLAMP = 280

function translateAboutDescription(description: string, t: (key: string) => string) {
  const lendMatch = description.match(
    /^(.*?) \((.*?)\) is a single-asset supply market on Avana\. Suppliers earn the supply APY( plus active rewards)? from borrower interest, net of the reserve factor\. Yield tracks utilization, so the page focuses on the live supply rate, the supply\/utilization mix, and the latest risk posture for this (stablecoin|tier-[a-z]+) market\.$/,
  )
  if (lendMatch) {
    const [, name, symbol, rewardsClause = "", marketType] = lendMatch
    return t(
      "{name} ({symbol}) is a single-asset supply market on Avana. Suppliers earn the supply APY{rewardsClause} from borrower interest, net of the reserve factor. Yield tracks utilization, so the page focuses on the live supply rate, the supply/utilization mix, and the latest risk posture for this {marketType} market.",
    )
      .replace("{name}", name)
      .replace("{symbol}", symbol)
      .replace("{rewardsClause}", rewardsClause)
      .replace("{marketType}", marketType)
  }

  const stockMatch = description.match(
    /^(.+?) is a tokenized-equity LP position posted as collateral inside the (.+?) spoke on Avana\. It pairs (.+?) with tokenized (.+?) \((.+?)\) exposure, so collateral value tracks the \4 share price alongside the pool's depth and fee tier\. Avana anchors borrow power to the spoke's max LTV, keeping credit tied to how sharply tokenized-equity collateral can move\. This page is the single source of truth for what the pool is, how much capital it can safely support, and the downside the protocol underwrites\.$/,
  )
  if (stockMatch) {
    const [, name, spoke, stableLeg, stockName, stockSymbol] = stockMatch
    return t(
      "{name} is a tokenized-equity LP position posted as collateral inside the {spoke} spoke on Avana. It pairs {stableLeg} with tokenized {stockName} ({stockSymbol}) exposure, so collateral value tracks the {stockName} share price alongside the pool's depth and fee tier. Avana anchors borrow power to the spoke's max LTV, keeping credit tied to how sharply tokenized-equity collateral can move. This page is the single source of truth for what the pool is, how much capital it can safely support, and the downside the protocol underwrites.",
    )
      .replaceAll("{name}", name)
      .replaceAll("{spoke}", spoke)
      .replaceAll("{stableLeg}", stableLeg)
      .replaceAll("{stockName}", stockName)
      .replaceAll("{stockSymbol}", stockSymbol)
  }

  return t(description)
}

export function AboutCard({ about, title = "About", compact = false, plain = false }: Props) {
  const { t } = useTranslation()
  const [expanded, setExpanded] = React.useState(false)

  const description = translateAboutDescription(about.description, t)
  const isLong = typeof description === "string" && description.length > DESCRIPTION_CLAMP
  const shownDescription = !isLong || expanded ? description : `${description.slice(0, DESCRIPTION_CLAMP).trimEnd()}… `
  const visibleStats = about.stats.filter((stat) => stat.label !== "Deployed On")
  const hasBody =
    (typeof description === "string" ? description.trim().length > 0 : Boolean(description)) || visibleStats.length > 0
  if (!hasBody) return null

  return (
    <section
      className={
        plain ? "space-y-4" : "overflow-hidden rounded-radius-lg border border-border bg-surface-raised shadow-elev-1"
      }
    >
      <div
        className={
          plain ? "flex items-center justify-between gap-3" : "flex items-center justify-between gap-3 px-4 py-3"
        }
      >
        <h2
          className={
            compact
              ? "truncate text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]"
              : "truncate text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]"
          }
        >
          {t(title)}
        </h2>
      </div>

      <SectionCardCopy className={plain ? undefined : "px-4"}>
        {shownDescription}
        {isLong ? (
          <button
            type="button"
            onClick={() => setExpanded((value) => !value)}
            className="font-medium text-sky-500 transition-colors hover:text-sky-400 focus-visible:outline-none focus-visible:underline"
          >
            {expanded ? t("show less") : t("read more")}
          </button>
        ) : null}
      </SectionCardCopy>

      {visibleStats.length > 0 ? (
        <dl className={plain ? "text-[14px]" : "px-4 pb-2 text-[14px]"}>
          {visibleStats.map((s) => {
            const help = ABOUT_CONTRACT_ADDRESS_HELP[s.label]
            return (
              <div key={s.label} className="flex items-center justify-between gap-4 py-2.5">
                <dt className="flex min-w-0 items-center gap-1.5 text-text-low">
                  <span className={s.href ? "min-w-0 truncate" : "truncate"}>{t(s.label)}</span>
                  {help ? <ActionMetricHelp text={help} topic={s.label} /> : null}
                </dt>
                <dd className="min-w-0 truncate text-right font-data font-medium tabular-nums text-text-extra-high">
                  {s.href ? (
                    <a
                      href={s.href}
                      target="_blank"
                      rel="noreferrer"
                      className="group flex items-center justify-end gap-2 text-text-extra-high transition-colors hover:text-text-high"
                    >
                      <span className="truncate font-data font-medium tabular-nums">{t(s.value)}</span>
                      <ArrowUpRight
                        className="size-4 shrink-0 text-text-low transition-colors group-hover:text-text-high"
                        aria-hidden
                      />
                    </a>
                  ) : (
                    t(s.value)
                  )}
                </dd>
              </div>
            )
          })}
        </dl>
      ) : null}
    </section>
  )
}
