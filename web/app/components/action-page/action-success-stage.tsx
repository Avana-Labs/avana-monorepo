"use client"

import { useState } from "react"
import type { ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { ActionFooter } from "@/app/components/action-page/action-amount-card"
import { TransactionReceipt, type TransactionReceiptData } from "@/app/components/action-page/transaction-receipt"
import { syntheticBlockFromHash } from "@/app/lib/action-system/synthetic-receipt"
import { avanaPlatformFeeUsd } from "@/app/lib/action-system/formatters"

export function ActionSuccessStage({
  success,
  closeHref,
  onPrimary,
  onSecondary,
  secondaryLabel,
}: {
  success: ActionSuccessUi
  closeHref?: string
  onPrimary?: () => void
  onSecondary?: () => void
  secondaryLabel?: string
}) {
  const receipt = success.receiptContext
  const hash = success.receiptHash
  // Stable per mount so re-renders (e.g. switching currency) don't bump the timestamp.
  const [dateMs] = useState(() => Date.now())

  const symbol = receipt?.amountLabel.split(" ").slice(-1)[0] ?? "Asset"

  // Transactions have no permalink page yet, so the hash renders as plain text.
  const hashHref: string | null = null

  const data: TransactionReceiptData = {
    title: success.title,
    description: success.description,
    symbol,
    amountRowLabel: receipt?.verb,
    amountLabel: receipt?.amountLabel,
    amountUsd: receipt?.amountUsd ?? null,
    rateLabel: receipt?.rateLabel ?? null,
    rateValue: receipt?.rateValue ?? null,
    marketValue: receipt?.marketValue ?? null,
    // Swaps carry their real quote fee on the receipt context; every other action
    // uses the canonical flat fee so the inline receipt matches the estimate and
    // the permalink instead of drifting to a hash-derived amount.
    networkFeeUsd: hash ? (receipt?.networkFeeUsd ?? avanaPlatformFeeUsd(receipt?.amountUsd ?? 0)) : null,
    block: hash ? syntheticBlockFromHash(hash) : null,
    dateMs,
    hash,
    hashHref,
    metrics: success.metrics,
    quoteId: success.quoteId,
  }

  return (
    <div data-testid="action-success-stage" className="space-y-4">
      <TransactionReceipt data={data} />

      <ActionFooter
        primaryLabel={success.primaryCtaLabel}
        secondaryLabel={secondaryLabel ?? success.secondaryCtaLabel}
        primaryHref={onPrimary ? undefined : success.primaryCtaHref}
        secondaryHref={onSecondary ? undefined : closeHref}
        onPrimary={onPrimary}
        onSecondary={onSecondary}
      />
    </div>
  )
}
