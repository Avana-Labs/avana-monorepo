"use client"

import type { ComponentProps } from "react"
import { CashflowCard } from "@/app/borrow/_detail/pool-sections/CashflowCard"
import {
  AllocationBreakdownCard,
  InterestRateModelCard,
  interestRateModelFromAssetDetail,
} from "@/app/borrow/_detail/asset-sections"
import { DetailFaqSection } from "@/app/borrow/_detail/ui/DetailFaqSection"
import {
  BORROW_ASSET_KIND_CONFIG,
  DetailMarketTransactions,
} from "@/app/components/detail-transaction-table/detail-market-transactions"
import { DetailPageNotice } from "@/app/components/detail-page-primitives"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { AssetDetail } from "@/app/lib/borrow-detail"

type TransactionProps = ComponentProps<typeof DetailMarketTransactions>

/**
 * The deferred analytics stack, as ONE lazily loaded module with plain imports. Each section used
 * to be its own lazy chunk that popped in at full height above content already on screen; loading
 * the stack whole lets it arrive at once, off screen, behind the shared placeholder.
 */
export function AssetAnalyticsStack({
  detail,
  seedRows,
  sessionRows,
}: {
  detail: AssetDetail
  seedRows: TransactionProps["seedRows"]
  sessionRows: TransactionProps["sessionRows"]
}) {
  const { t } = useTranslation()
  return (
    <>
      <InterestRateModelCard {...interestRateModelFromAssetDetail(detail)} />
      <AllocationBreakdownCard detail={detail} />
      <CashflowCard detail={detail} />
      <DetailMarketTransactions
        scope="asset"
        slug={detail.row.id}
        seedRows={seedRows}
        sessionRows={sessionRows}
        kindConfig={BORROW_ASSET_KIND_CONFIG}
        context={{ assetSymbol: detail.hero.symbol }}
      />
      <DetailFaqSection
        title={t("General FAQs")}
        items={detail.faqs.map((faq) => ({ question: faq.question, answer: <p>{faq.answer}</p> }))}
      />
      <DetailPageNotice product="borrow" />
    </>
  )
}
