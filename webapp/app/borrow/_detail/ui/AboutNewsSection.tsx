"use client"

import type * as React from "react"
import { cn } from "@/lib/utils"
import type { AboutCard as AboutCardData } from "@/app/lib/borrow-detail"
import { ArrowUpRight } from "@/app/components/icons"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { AboutCard } from "@/app/borrow/_detail/pool-sections"
import { NewsCard } from "./NewsCard"
import { buildNewsItems } from "@/app/borrow/_detail/lib/news"
import { normalizeGovernanceParameters } from "@/app/borrow/_detail/lib/governance-parameters"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { TablePager, useTablePagination } from "@/app/components/table-pager"

/** Trim role suffixes ("executor"/"multisig") so the changelog second line fits on one line. */
function shortExecutor(executor: string): string {
  return executor.replace(/\s+(executor|multisig)$/i, "")
}

type Props = {
  about: AboutCardData
  newsImageUrl?: string
  newsImageLabel?: string
  aboutTitle?: string
  compactAboutTitle?: boolean
  newsTitle?: string
  /** Optional outbound link for "View all" / items. Never default to Aave governance. */
  governanceUrl?: string
  /** Legacy prop; media placement is now fixed to the news-style thumbnail. */
  mediaVariant?: "card" | "icon"
  afterAbout?: React.ReactNode
  className?: string
}

export function AboutNewsSection({
  about,
  newsImageUrl,
  newsImageLabel,
  aboutTitle = "About",
  compactAboutTitle = false,
  newsTitle = "Risk Parameters",
  governanceUrl,
  afterAbout,
  className,
}: Props) {
  const { t } = useTranslation()
  const newsItems = buildNewsItems(about, newsImageUrl, newsImageLabel)
  const governanceParameters = normalizeGovernanceParameters(about)
  const changelog = useTablePagination(governanceParameters?.changelog ?? [], 5)

  return (
    <div className={cn(detailSectionStackClass, "pt-10", className)}>
      <AboutCard about={about} title={aboutTitle} compact={compactAboutTitle} plain />
      {afterAbout}
      {governanceParameters ? (
        <>
          <section aria-label={t(newsTitle)} className="space-y-5">
            <div className="flex items-center justify-between gap-3">
              <h2 className="truncate text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                {t(newsTitle)}
              </h2>
              {governanceUrl ? (
                <a
                  href={governanceUrl}
                  target="_blank"
                  rel="noreferrer"
                  className="shrink-0 text-[13px] font-medium text-sky-500 transition-colors hover:text-sky-400"
                >
                  {t("View all")}
                </a>
              ) : null}
            </div>

            <div className="grid grid-cols-2 gap-x-6 gap-y-6 lg:grid-cols-4 lg:gap-x-8">
              {governanceParameters.parameters.map((parameter) => {
                const parameterContent = (
                  <>
                    <div className="flex min-w-0 items-start justify-between gap-4">
                      <div className="min-w-0">
                        <div className="flex items-center gap-1 text-[14px] font-normal leading-snug text-muted-foreground">
                          {t(parameter.label)}
                          {parameter.description ? (
                            <ActionMetricHelp text={parameter.description} topic={parameter.label} />
                          ) : null}
                        </div>
                      </div>
                      {parameter.status ? (
                        <span className="shrink-0 rounded-full bg-surface-inset px-2.5 py-1 text-[12px] font-medium leading-none text-muted-foreground">
                          {t(parameter.status)}
                        </span>
                      ) : null}
                    </div>
                    <div className="mt-2 font-data text-[22px] font-normal leading-none tracking-[-0.01em] text-foreground">
                      {t(parameter.value)}
                    </div>
                  </>
                )

                return parameter.href ? (
                  <a
                    key={parameter.id}
                    href={parameter.href}
                    target="_blank"
                    rel="noreferrer"
                    className="group min-w-0 transition-colors"
                  >
                    {parameterContent}
                  </a>
                ) : (
                  <article key={parameter.id} className="min-w-0">
                    {parameterContent}
                  </article>
                )
              })}
            </div>
          </section>

          <section aria-label={t("Parameter changelog")} className="space-y-5">
            <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
              {t("Parameter changelog")}
            </h2>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[560px] table-fixed border-separate border-spacing-0 text-[13px]">
                <colgroup>
                  <col className="w-[42%]" />
                  <col className="w-[17%]" />
                  <col className="w-[21%]" />
                  <col className="w-[20%]" />
                </colgroup>
                <thead>
                  <tr className="bg-table-header text-left text-muted-foreground">
                    <th className="bg-table-header pb-2 pl-5 pr-4 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58">
                      {t("Parameter")}
                    </th>
                    <th className="bg-table-header px-4 pb-2 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58">
                      {t("Previous")}
                    </th>
                    <th className="bg-table-header px-4 pb-2 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58">
                      {t("Current")}
                    </th>
                    <th className="bg-table-header px-4 pb-2 pr-5 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58">
                      {t("Date")}
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border dark:divide-white/6">
                  {changelog.pageItems.map((entry) => (
                    <tr key={entry.id} className="transition-colors hover:bg-hover">
                      <th scope="row" className="py-3 pl-5 pr-4 text-left align-top">
                        <span className="block text-[13px] font-medium text-foreground">{t(entry.parameter)}</span>
                        <span className="mt-0.5 block text-[12px] font-normal leading-snug text-muted-foreground">
                          {t(entry.source)} · {shortExecutor(t(entry.executor))}
                        </span>
                      </th>
                      <td className="px-4 py-3 align-top font-data text-[13px] font-medium tabular-nums text-muted-foreground">
                        {t(entry.previous)}
                      </td>
                      <td className="px-4 py-3 align-top font-data text-[13px] font-medium leading-snug tabular-nums text-foreground !whitespace-normal [overflow-wrap:anywhere]">
                        {t(entry.current)}
                      </td>
                      <td className="px-4 py-3 pr-5 align-top text-[13px] text-muted-foreground">
                        <span className="inline-flex items-center gap-1.5">
                          {t(entry.date)}
                          {entry.href ? (
                            <a
                              href={entry.href}
                              target="_blank"
                              rel="noreferrer"
                              aria-label={t("View transaction")}
                              className="text-muted-foreground transition-colors hover:text-foreground"
                            >
                              <ArrowUpRight className="h-3.5 w-3.5" />
                            </a>
                          ) : null}
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <TablePager
              page={changelog.page}
              pageCount={changelog.pageCount}
              onPageChange={changelog.setPage}
              label={t("Changelog pagination")}
            />
          </section>
        </>
      ) : newsItems.length > 0 ? (
        <NewsCard
          items={newsItems}
          title={newsTitle}
          viewAllHref={governanceUrl}
          itemHrefFallback={governanceUrl}
          plain
        />
      ) : null}
    </div>
  )
}
