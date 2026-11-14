"use client"

import { useCallback, useMemo, useState } from "react"
import { TRANSACTIONS_UNAVAILABLE } from "@/app/lib/borrow-system/production-transaction-adapter"
import {
  unsupportedSwapQuote,
  type SwapExecutionOptions,
  type SwapQuote,
  type SwapQuoteRequest,
  type SwapSystemState,
  type SwapTransactionRecord,
} from "./quote-types"
import type { UserAssetBalance } from "./contracts"

/**
 * Swap state of one wallet. Quotes will come from CoW Swap and balances from ERC-20 reads; until
 * then every quote is "unsupported", balances are empty and no approval or swap runs.
 */
export function useSwapSession({ walletId }: { walletId: string }) {
  const [state, setState] = useState<SwapSystemState>({ balances: [], allowances: {}, transactions: [] })

  const walletBalances = useMemo(
    () => state.balances.filter((balance): balance is UserAssetBalance => balance.walletId === walletId),
    [state.balances, walletId],
  )

  const getQuote = useCallback(
    async (request: Omit<SwapQuoteRequest, "walletId">): Promise<SwapQuote> =>
      unsupportedSwapQuote({ ...request, walletId }),
    [walletId],
  )
  const getIndicativeQuote = getQuote
  const requiresApproval = useCallback((_assetId: string, _amount: number) => false, [])
  const approve = useCallback(
    async (_assetId: string, _amount: number, _options?: SwapExecutionOptions): Promise<SwapTransactionRecord> => {
      throw new Error(TRANSACTIONS_UNAVAILABLE)
    },
    [],
  )
  const executeSwap = useCallback(
    async (_quote: SwapQuote, _options?: SwapExecutionOptions): Promise<SwapTransactionRecord> => {
      throw new Error(TRANSACTIONS_UNAVAILABLE)
    },
    [],
  )
  const hydrateBalances = useCallback(
    (balances: UserAssetBalance[]) => {
      setState((current) => ({
        ...current,
        balances: balances.map((balance) => ({ ...balance, walletId: balance.walletId || walletId })),
      }))
    },
    [walletId],
  )

  const isHydrated = true
  const transactionHistory = state.transactions

  return useMemo(
    () => ({
      walletId,
      isHydrated,
      state,
      walletBalances,
      transactionHistory,
      getQuote,
      getIndicativeQuote,
      requiresApproval,
      approve,
      executeSwap,
      hydrateBalances,
    }),
    [
      walletId,
      isHydrated,
      state,
      walletBalances,
      transactionHistory,
      getQuote,
      getIndicativeQuote,
      requiresApproval,
      approve,
      executeSwap,
      hydrateBalances,
    ],
  )
}
