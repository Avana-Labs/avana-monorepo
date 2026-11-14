import type { LendMarket, LendSystemState } from "@/app/lib/lend-system/model"
import { resolveLendMarketId } from "./market-ids"

export function getWalletBalanceForLendMarket(
  state: Pick<Partial<LendSystemState>, "walletBalances">,
  walletId: string,
  market: Pick<LendMarket, "marketId">,
): number {
  return state.walletBalances?.[walletId]?.[resolveLendMarketId(market.marketId)] ?? 0
}
