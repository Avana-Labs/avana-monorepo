"use client"

import type { ComponentProps } from "react"
import { CashflowCard } from "@/app/borrow/_detail/pool-sections/CashflowCard"
import { InterestRateModelCard } from "@/app/borrow/_detail/asset-sections"
import { DetailFaqSection } from "@/app/borrow/_detail/ui/DetailFaqSection"
import {
  LEND_KIND_CONFIG,
  DetailMarketTransactions,
} from "@/app/components/detail-transaction-table/detail-market-transactions"
import { DetailPageNotice } from "@/app/components/detail-page-primitives"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { LendMarketDetail } from "@/app/lib/lend-detail"

type TransactionProps = ComponentProps<typeof DetailMarketTransactions>

/**
 * The deferred analytics stack, as ONE lazily loaded module with plain imports. Each section used
 * to be its own lazy chunk that popped in at full height above content already on screen; loading
 * the stack whole lets it arrive at once, off screen, behind the shared placeholder.
 */
export function LendAnalyticsStack({
  detail,
  seedRows,
  sessionRows,
  marketId,
}: {
  detail: LendMarketDetail
  seedRows: TransactionProps["seedRows"]
  sessionRows: TransactionProps["sessionRows"]
  marketId: string
}) {
  const { t } = useTranslation()
  return (
    <>
      <InterestRateModelCard
        utilizationPct={detail.utilizationPct}
        borrowAprPct={detail.borrowAprPct}
        protocolParameters={detail.protocolParameters}
        borrowedUsd={detail.supplyBorrow.borrowed.aggregate ?? detail.supplyBorrow.borrowed.points.at(-1)?.v}
        suppliedUsd={detail.supplyBorrow.supplied.aggregate ?? detail.supplyBorrow.supplied.points.at(-1)?.v}
      />
      <CashflowCard detail={detail} />
      <DetailMarketTransactions
        scope="lend"
        slug={marketId}
        seedRows={seedRows}
        sessionRows={sessionRows}
        kindConfig={LEND_KIND_CONFIG}
        context={{ assetSymbol: detail.hero.symbol }}
      />
      <DetailFaqSection
        title={t("General FAQs")}
        items={detail.faqs.map((faq) => ({ question: faq.question, answer: <p>{faq.answer}</p> }))}
      />
      <DetailPageNotice product="lend" />
    </>
  )
}
