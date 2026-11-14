import type { BorrowSystemState } from "@/app/lib/credit-engine"
import { formatFixed } from "@/app/lib/credit-engine"

export function getWalletLpBalanceUsd(state: BorrowSystemState, walletId: string, marketId: string): number {
  const balanceUsd6 = state.accounts[walletId]?.walletLpBalancesUsd6[marketId] ?? 0n
  return Number.parseFloat(formatFixed(balanceUsd6, 6))
}
