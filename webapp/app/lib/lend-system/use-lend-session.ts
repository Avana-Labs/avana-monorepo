"use client"

import { useCallback, useMemo, useRef, useState } from "react"
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
import { executeLendOnChain } from "./chain-execution"
import { lendHubAssets } from "./chain-lend-refs"
import { chainBorrowRefs } from "@/app/lib/borrow-system/chain-refs"
import { connectedBorrowWallet, viemBorrowChain } from "@/app/lib/borrow-system/chain-execution-viem"
import { requestLendPositionsRefresh } from "./use-chain-lend-positions"
import { emptyLendSystemState, mergeConvexLendSnapshots, type LendConvexSnapshot } from "./market-hydration"
import { mergeChainLendPositions, type ChainLendRead } from "./chain-lend-positions"
import { buildLendPageData, buildLendWalletSnapshot, buildPortfolioLendData } from "./read-model"

export { emptyLendSystemState }

/**
 * Lend state of one wallet: the Hub assets services/convex reports, and the wallet's supplies and token balances read
 * from the chain (Lend Spoke `getUserSuppliedAssets`, ERC-20 `balanceOf`, through `hydratePositions`). Actions answer
 * "not available yet".
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
  // The latest state, for the adapters' builders without re-creating them on every change.
  const stateRef = useRef(state)
  stateRef.current = state

  const transactionAdapter = useMemo(
    () =>
      injectedTransactionAdapter ??
      new ProductionLendTransactionAdapter({
        executeTransaction: (intent) =>
          executeLendOnChain(
            {
              hubAssets: lendHubAssets,
              lens: (wallet, chainId) => chainBorrowRefs(wallet)?.lenses.find((l) => l.chainId === chainId)?.lens,
              chain: viemBorrowChain,
              wallet: connectedBorrowWallet,
              state: () => stateRef.current,
              onConfirmed: requestLendPositionsRefresh,
            },
            intent,
          ),
      }),
    [injectedTransactionAdapter],
  )
  const readAdapter = useMemo(
    () =>
      injectedReadAdapter ??
      new ProductionLendReadAdapter({
        readWalletSnapshot: async (id) => buildLendWalletSnapshot(id, stateRef.current, transactionHistory),
        readMarkets: async () => Object.values(stateRef.current.markets),
        readLendPage: async (id) => buildLendPageData(id, stateRef.current),
        readPortfolioLend: async (id) => buildPortfolioLendData(id, stateRef.current, transactionHistory),
      }),
    [injectedReadAdapter, transactionHistory],
  )

  const hydrateMarketData = useCallback((snapshots: readonly LendConvexSnapshot[]) => {
    setState((prev) => mergeConvexLendSnapshots(prev, snapshots))
  }, [])
  /** The wallet's supplies and token balances, read from the chain (`chain-lend-positions.ts`). */
  const hydratePositions = useCallback(
    (read: ChainLendRead) => {
      setState((prev) => mergeChainLendPositions(prev, walletId, read))
    },
    [walletId],
  )

  const createIntent = useCallback(
    (action: LendAction) => transactionAdapter.createIntent(action),
    [transactionAdapter],
  )
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
      hydratePositions,
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
      hydratePositions,
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
