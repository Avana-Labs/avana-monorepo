"use client"

import { BorrowActionPageClient } from "@/app/components/action-page/borrow-action-page-client"
import { ResponsiveDetailAction } from "@/app/components/action-page/responsive-detail-action"
import type { ActionKind } from "@/app/lib/action-system/contracts"

type BorrowActionKind = Extract<ActionKind, "borrow" | "repay" | "supply" | "remove" | "claim">

export function ResponsiveBorrowAction({
  kind,
  market,
  asset,
  amount,
  closeHref,
  label,
  sidebar = false,
}: {
  kind: BorrowActionKind
  market?: string
  asset?: string
  amount?: string
  closeHref: string
  label?: string
  sidebar?: boolean
}) {
  return (
    <ResponsiveDetailAction
      product="borrow"
      kind={kind}
      market={market}
      asset={asset}
      amount={amount}
      closeHref={closeHref}
      label={label}
      sidebar={sidebar}
    >
      <BorrowActionPageClient
        kind={kind}
        embedded
        sidebar={sidebar}
        layout="default"
        closeHref={closeHref}
        initialMarketId={market}
        initialAssetId={asset}
        initialAmount={amount}
      />
    </ResponsiveDetailAction>
  )
}
