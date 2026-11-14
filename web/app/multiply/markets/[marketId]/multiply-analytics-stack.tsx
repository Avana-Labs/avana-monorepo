"use client"

import type { ComponentProps } from "react"
import { CashflowCard } from "@/app/borrow/_detail/pool-sections/CashflowCard"
import { LiquidationRiskSection } from "@/app/borrow/_detail/ui/LiquidationRiskSection"
import { DetailFaqSection } from "@/app/borrow/_detail/ui/DetailFaqSection"
import {
  MULTIPLY_KIND_CONFIG,
  DetailMarketTransactions,
} from "@/app/components/detail-transaction-table/detail-market-transactions"
import { DetailPageNotice } from "@/app/components/detail-page-primitives"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { MultiplyMarketDetail } from "@/app/lib/multiply-detail"

type TransactionProps = ComponentProps<typeof DetailMarketTransactions>

/**
 * The deferred analytics stack, as ONE lazily loaded module with plain imports. Each section used
 * to be its own lazy chunk that popped in at full height above content already on screen; loading
 * the stack whole lets it arrive at once, off screen, behind the shared placeholder.
 */
export function MultiplyAnalyticsStack({
  detail,
  seedRows,
  sessionRows,
  marketId,
}: {
  detail: MultiplyMarketDetail
  seedRows: TransactionProps["seedRows"]
  sessionRows: TransactionProps["sessionRows"]
  marketId: string
}) {
  const { t } = useTranslation()
  return (
    <>
      <CashflowCard detail={detail} />
      {detail.liquidationRisk && detail.liquidationRisk.length > 0 ? (
        <LiquidationRiskSection stats={detail.liquidationRisk} />
      ) : null}
      <DetailMarketTransactions
        scope="multiply"
        slug={marketId}
        seedRows={seedRows}
        sessionRows={sessionRows}
        kindConfig={MULTIPLY_KIND_CONFIG}
        context={{
          collateralSymbol: detail.row.protocol,
          borrowableSymbol: detail.row.asset,
        }}
      />
      <DetailFaqSection
        title={t("Multiply FAQs")}
        items={detail.faqs.map((faq) => ({ question: faq.question, answer: <p>{faq.answer}</p> }))}
      />
      <DetailPageNotice product="multiply" />
    </>
  )
}
