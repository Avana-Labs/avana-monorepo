"use client"

import type { ComponentProps } from "react"
import { CashflowCard } from "@/app/borrow/_detail/pool-sections/CashflowCard"
import { AssetsYouCanBorrowSection } from "@/app/borrow/_detail/ui/CrossMarketReferenceSections"
import { LiquidationRiskSection } from "@/app/borrow/_detail/ui/LiquidationRiskSection"
import { DetailFaqSection } from "@/app/borrow/_detail/ui/DetailFaqSection"
import { resolveBorrowablesForPool } from "@/app/lib/borrow-detail/cross-market"
import {
  BORROW_POOL_KIND_CONFIG,
  DetailMarketTransactions,
} from "@/app/components/detail-transaction-table/detail-market-transactions"
import { DetailPageNotice } from "@/app/components/detail-page-primitives"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { PoolDetail } from "@/app/lib/borrow-detail"

type TransactionProps = ComponentProps<typeof DetailMarketTransactions>

/**
 * The deferred analytics stack, as ONE lazily loaded module with plain imports. Each section used
 * to be its own lazy chunk that popped in at full height above content already on screen; loading
 * the stack whole lets it arrive at once, off screen, behind the shared placeholder.
 */
export function PoolAnalyticsStack({
  detail,
  seedRows,
  sessionRows,
}: {
  detail: PoolDetail
  seedRows: TransactionProps["seedRows"]
  sessionRows: TransactionProps["sessionRows"]
}) {
  const { t } = useTranslation()
  return (
    <>
      <CashflowCard detail={detail} />
      <AssetsYouCanBorrowSection
        collateralLabel={detail.hero.name}
        assets={detail.borrowableAssets ?? resolveBorrowablesForPool(detail.row)}
      />
      {detail.liquidationRisk && detail.liquidationRisk.length > 0 ? (
        <LiquidationRiskSection stats={detail.liquidationRisk} />
      ) : null}
      <DetailMarketTransactions
        scope="pool"
        slug={detail.row.id}
        seedRows={seedRows}
        sessionRows={sessionRows}
        preset="pool"
        kindConfig={BORROW_POOL_KIND_CONFIG}
        context={{
          token0Symbol: detail.hero.visuals[0]?.symbol ?? "",
          token1Symbol: detail.hero.visuals[1]?.symbol ?? "",
          token0Weight: String(detail.row.constituents[0]?.weight ?? 0.5),
          token1Weight: String(detail.row.constituents[1]?.weight ?? 0.5),
        }}
      />
      <DetailFaqSection
        title={t("General FAQs")}
        items={detail.faqs.map((faq) => ({ question: faq.question, answer: <p>{faq.answer}</p> }))}
      />
      <DetailPageNotice product="borrow" />
    </>
  )
}
