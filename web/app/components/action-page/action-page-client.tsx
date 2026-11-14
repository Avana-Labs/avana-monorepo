"use client"

import type { ActionKind, ActionProduct } from "@/app/lib/action-system/contracts"
import { isValidAction, normalizeActionKind } from "@/app/lib/action-system/contracts"
import { ActionNotFound } from "@/app/components/action-page/action-not-found"
import { BorrowActionPageClient } from "@/app/components/action-page/borrow-action-page-client"
import { LendActionPageClient } from "@/app/components/action-page/lend-action-page-client"
import { MultiplyActionPageClient } from "@/app/components/action-page/multiply-action-page-client"
import { RewardsActionPageClient } from "@/app/components/action-page/rewards-action-page-client"
import { UmbrellaActionPageClient } from "@/app/components/action-page/umbrella-action-page-client"

export function ActionPageClient({
  product,
  kind,
  closeHref,
  initialAssetId,
  initialMarketId,
  initialAmount,
  initialMultiplier,
  initialPositionId,
  initialDebtId,
}: {
  product: ActionProduct
  kind: ActionKind
  closeHref?: string
  initialAssetId?: string
  initialMarketId?: string
  initialAmount?: string
  initialMultiplier?: string
  initialPositionId?: string
  initialDebtId?: string
}) {
  if (!isValidAction(product, kind)) {
    const fallbackHref =
      closeHref ??
      (product === "lend" || product === "multiply" || product === "borrow" || product === "umbrella"
        ? `/${product}`
        : "/")
    return <ActionNotFound closeHref={fallbackHref} />
  }

  const resolvedKind = normalizeActionKind(product, kind)

  if (product === "borrow") {
    return (
      <BorrowActionPageClient
        kind={resolvedKind as "borrow" | "repay" | "supply" | "remove" | "claim"}
        closeHref={closeHref}
        initialAssetId={initialAssetId}
        initialMarketId={initialMarketId}
        initialAmount={initialAmount}
        initialPositionId={initialPositionId}
        initialDebtId={initialDebtId}
      />
    )
  }

  if (product === "lend") {
    return (
      <LendActionPageClient
        kind={kind as "deposit" | "withdraw"}
        closeHref={closeHref ?? "/lend"}
        initialAssetId={initialAssetId}
        initialMarketId={initialMarketId}
        initialAmount={initialAmount}
      />
    )
  }

  if (product === "multiply") {
    return (
      <MultiplyActionPageClient
        kind={kind as "multiply" | "deleverage" | "close"}
        closeHref={closeHref ?? "/multiply"}
        initialMarketId={initialMarketId}
        initialAmount={initialAmount}
        initialMultiplier={initialMultiplier}
      />
    )
  }

  if (product === "umbrella") {
    return (
      <UmbrellaActionPageClient
        kind={kind as "stake" | "claim" | "cooldown" | "unstake"}
        closeHref={closeHref ?? "/umbrella"}
        initialMarketId={initialMarketId}
      />
    )
  }

  return <RewardsActionPageClient closeHref={closeHref ?? "/dashboard"} />
}
