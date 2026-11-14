"use client"

import { useCallback, useMemo, useState } from "react"
import type { LendAction, LendSystemState } from "@/app/lib/lend-system/model"
import type {
  LendReadAdapter,
  LendActionResult,
  LendTransactionAdapter,
  LendTransactionHistoryItem,
  LendTransactionIntent,
  LendTransactionResult,
} from "./contracts"
import { ProductionLendReadAdapter } from "./production-read-adapter"
import { ProductionLendTransactionAdapter } from "./production-transaction-adapter"
import { mergeConvexLendSnapshots, type LendConvexSnapshot } from "./market-hydration"

export function emptyLendSystemState(walletId: string, now = Date.now()): LendSystemState {
  return { now, markets: {}, positions: {}, walletBalances: { [walletId]: {} }, transactions: [] }
}

/**
 * Lend state of one wallet: the Hub assets services/convex reports and the wallet's supplies.
 * Supplies and wallet balances stay empty until the chain reads (Lend Spoke
 * `getUserSuppliedAssets`, ERC-20 `balanceOf`) are wired; actions answer "not available yet".
 */
export function useLendSession({
  walletId,
  readAdapter: injectedReadAdapter,
  transactionAdapter: injectedTransactionAdapter,
}: {
  walletId: string
  readAdapter?: LendReadAdapter
  transactionAdapter?: LendTransactionAdapter
}) {
  const [state, setState] = useState<LendSystemState>(() => emptyLendSystemState(walletId))
  const [transactionHistory] = useState<LendTransactionHistoryItem[]>([])
  const [transactionReceipts] = useState<LendTransactionResult[]>([])
  const [isPending, setIsPending] = useState(false)

  const transactionAdapter = useMemo(
    () => injectedTransactionAdapter ?? new ProductionLendTransactionAdapter(),
    [injectedTransactionAdapter],
  )
  const readAdapter = useMemo(() => injectedReadAdapter ?? new ProductionLendReadAdapter(), [injectedReadAdapter])

  const hydrateMarketData = useCallback((snapshots: readonly LendConvexSnapshot[]) => {
    setState((prev) => mergeConvexLendSnapshots(prev, snapshots))
  }, [])

  const createIntent = useCallback((action: LendAction) => transactionAdapter.createIntent(action), [transactionAdapter])
  const previewTransaction = useCallback(
    (intent: LendTransactionIntent) => transactionAdapter.previewTransaction(intent),
    [transactionAdapter],
  )
  const executeTransaction = useCallback(
    async (intent: LendTransactionIntent): Promise<LendActionResult> => {
      setIsPending(true)
      try {
        return await transactionAdapter.executeTransaction(intent)
      } finally {
        setIsPending(false)
      }
    },
    [transactionAdapter],
  )
  const claimRewards = useCallback(async () => {
    const intent = transactionAdapter.createIntent({ type: "claim", walletId })
    return executeTransaction(intent)
  }, [executeTransaction, transactionAdapter, walletId])

  const reset = useCallback(() => {
    setState((current) => ({ ...emptyLendSystemState(walletId), markets: current.markets }))
  }, [walletId])

  const isHydrated = true

  return useMemo(
    () => ({
      walletId,
      state,
      readAdapter,
      transactionHistory,
      transactionReceipts,
      hydrateMarketData,
      createIntent,
      previewTransaction,
      executeTransaction,
      claimRewards,
      reset,
      isPending,
      isHydrated,
    }),
    [
      walletId,
      state,
      readAdapter,
      transactionHistory,
      transactionReceipts,
      hydrateMarketData,
      createIntent,
      previewTransaction,
      executeTransaction,
      claimRewards,
      reset,
      isPending,
      isHydrated,
    ],
  )
}
