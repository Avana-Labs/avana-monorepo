import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"
import { getSwapAsset, type SwapTransactionRecord } from "@/app/lib/swap-system"
import type { DurableSwapTransaction } from "@/app/lib/swap-system/use-swap-session"

function activityStatus(status: SwapTransactionRecord["status"]): PortfolioActivityRow["status"] {
  if (status === "confirmed") return "confirmed"
  if (status === "approval_pending" || status === "approval_confirmed" || status === "swap_pending") {
    return "pending"
  }
  return "failed"
}

function formatAmount(amount: number) {
  return amount.toLocaleString(undefined, { maximumFractionDigits: 6 })
}

/**
 * Map durable, Convex-persisted swaps into dashboard activity rows so a swap survives reload
 * and appears cross-device (#15 follow-on). The row `id` is the client swap intentId, so it
 * dedups 1:1 against the in-session row (which keys on the same client id) — the two hashes
 * differ (client `0xswap…` vs server `sim-swap…`), so id-dedup, not hash-dedup, is required.
 */
export function mapConvexSwapTransactionsToActivityRows(rows: DurableSwapTransaction[]): PortfolioActivityRow[] {
  return rows.map((row) => ({
    id: row.intentId ?? row.id,
    at: new Date(row.at).toISOString(),
    product: "swap",
    kind: "swap",
    status: row.status === "success" ? "confirmed" : row.status === "pending" ? "pending" : "failed",
    // Server already stores amountUsd 0 for a non-success swap; negate only the confirmed one.
    amountUsd: row.status === "success" ? -row.amountUsd : 0,
    primaryLabel: `${formatAmount(row.inputAmount)} ${row.inputSymbol} → ${formatAmount(row.outputAmount)} ${row.outputSymbol}`,
    secondaryLabel: row.status === "success" ? "Swap" : row.status,
    txHash: row.hash,
  }))
}

export function mapSwapTransactionHistoryToActivityRows(transactions: SwapTransactionRecord[]): PortfolioActivityRow[] {
  return transactions.map((transaction) => {
    const inputAsset = getSwapAsset(transaction.inputAssetId)
    const outputAsset = getSwapAsset(transaction.outputAssetId)
    const inputSymbol = inputAsset?.symbol ?? transaction.inputAssetId.toUpperCase()
    const outputSymbol = outputAsset?.symbol ?? transaction.outputAssetId.toUpperCase()
    const txHash = transaction.swapTransactionHash ?? transaction.approvalTransactionHash ?? transaction.id

    return {
      id: transaction.id,
      at: new Date(transaction.confirmedAt ?? transaction.createdAt).toISOString(),
      product: "swap",
      kind: "swap",
      status: activityStatus(transaction.status),
      // Only a confirmed swap actually debits the wallet; a failed/expired/rejected
      // (or still-pending) swap moved no funds, so it must not show a debit. (#31)
      amountUsd: transaction.status === "confirmed" ? -(transaction.inputAmount * (inputAsset?.priceUsd ?? 0)) : 0,
      primaryLabel: `${formatAmount(transaction.inputAmount)} ${inputSymbol} → ${formatAmount(transaction.outputAmount)} ${outputSymbol}`,
      secondaryLabel:
        transaction.status === "confirmed"
          ? transaction.provider
          : (transaction.failureReason ?? transaction.status.replaceAll("_", " ")),
      txHash,
    }
  })
}
