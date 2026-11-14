"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import { calculateCreditMetrics, type BorrowAction, type BorrowSystemState } from "@/app/lib/borrow-system/model"
import {
  emptyBorrowSystemState,
  mergeConvexMarketSnapshots,
  type ConvexMarketSnapshot,
} from "@/app/lib/borrow-system/market-hydration"
import type {
  BaseReadAdapter,
  ActionResult,
  SyntheticTransactionReceipt,
  TransactionAdapter,
  TransactionHistoryItem,
  TransactionIntent,
} from "@/app/lib/borrow-system/contracts"
import { ProductionTransactionAdapter } from "@/app/lib/borrow-system/production-transaction-adapter"
import { ProductionBorrowReadAdapter } from "@/app/lib/borrow-system/production-read-adapter"
import {
  selectBorrowableAssets,
  selectAllAvailableCollateralPools,
  selectBorrowCollateralPools,
  selectBorrowMarketSummaries,
  selectInitialBorrowDebts,
  selectWalletBorrowSnapshot,
} from "@/app/lib/borrow-system/selectors"

/**
 * Borrow state of one wallet: the markets services/convex reports and the wallet's account.
 * Accounts stay empty until the chain reads (Lens `getAccount`, the wallet's PositionProxy
 * accounts) are wired; actions go through the production transaction adapter, which answers
 * "not available yet" until contract calls land.
 */
export function useBorrowSession({
  walletId,
  readAdapter: injectedReadAdapter,
  transactionAdapter: injectedTransactionAdapter,
}: {
  walletId: string
  readAdapter?: BaseReadAdapter
  transactionAdapter?: TransactionAdapter
}) {
  const [state, setState] = useState<BorrowSystemState>(() => emptyBorrowSystemState(walletId))
  const [transactionHistory] = useState<TransactionHistoryItem[]>([])
  const [transactionReceipts] = useState<SyntheticTransactionReceipt[]>([])
  const [isPending, setIsPending] = useState(false)

  // A wallet switch starts from an empty account; the markets are kept.
  useEffect(() => {
    setState((current) =>
      current.accounts[walletId] ? current : { ...emptyBorrowSystemState(walletId), markets: current.markets, assets: current.assets },
    )
  }, [walletId])

  const reset = useCallback(() => {
    setState((current) => ({ ...emptyBorrowSystemState(walletId), markets: current.markets, assets: current.assets }))
  }, [walletId])

  /** Replace the markets with the rows services/convex reports. Wallet accounts are untouched. */
  const hydrateMarketData = useCallback((snapshots: readonly ConvexMarketSnapshot[]) => {
    setState((prev) => mergeConvexMarketSnapshots(prev, snapshots))
  }, [])

  const transactionAdapter = useMemo(
    () => injectedTransactionAdapter ?? new ProductionTransactionAdapter(),
    [injectedTransactionAdapter],
  )

  const createIntent = useCallback(
    (action: BorrowAction) => transactionAdapter.createIntent(action),
    [transactionAdapter],
  )
  const previewTransaction = useCallback(
    (intent: TransactionIntent) => transactionAdapter.previewTransaction(intent),
    [transactionAdapter],
  )
  const executeTransaction = useCallback(
    async (intent: TransactionIntent): Promise<ActionResult> => {
      setIsPending(true)
      try {
        return await transactionAdapter.executeTransaction(intent)
      } finally {
        setIsPending(false)
      }
    },
    [transactionAdapter],
  )
  const readAdapter = useMemo(() => injectedReadAdapter ?? new ProductionBorrowReadAdapter(), [injectedReadAdapter])

  const metrics = useMemo(() => calculateCreditMetrics(state, walletId), [state, walletId])
  const marketSummaries = useMemo(() => selectBorrowMarketSummaries(state, walletId), [state, walletId])
  const borrowableAssets = useMemo(() => selectBorrowableAssets(state, walletId), [state, walletId])
  const collateralPools = useMemo(() => selectBorrowCollateralPools(state, walletId), [state, walletId])
  const availableCollateralPools = useMemo(() => selectAllAvailableCollateralPools(state, walletId), [state, walletId])
  const initialDebts = useMemo(() => selectInitialBorrowDebts(state, walletId), [state, walletId])
  const walletSnapshot = useMemo(() => selectWalletBorrowSnapshot(state, walletId), [state, walletId])

  const getBorrowableAssetsForMarket = useCallback(
    (marketId?: string) => selectBorrowableAssets(state, walletId, marketId),
    [state, walletId],
  )

  const lastReceipt = transactionReceipts[0] ?? null
  // Nothing wallet-specific loads yet, so the session is ready as soon as it mounts.
  const isHydrated = true

  return useMemo(
    () => ({
      state,
      metrics,
      marketSummaries,
      borrowableAssets,
      collateralPools,
      availableCollateralPools,
      initialDebts,
      walletSnapshot,
      transactionHistory,
      transactionReceipts,
      lastReceipt,
      isPending,
      isHydrated,
      getBorrowableAssetsForMarket,
      readAdapter,
      createIntent,
      previewTransaction,
      executeTransaction,
      reset,
      hydrateMarketData,
    }),
    [
      state,
      metrics,
      marketSummaries,
      borrowableAssets,
      collateralPools,
      availableCollateralPools,
      initialDebts,
      walletSnapshot,
      transactionHistory,
      transactionReceipts,
      lastReceipt,
      isPending,
      isHydrated,
      getBorrowableAssetsForMarket,
      readAdapter,
      createIntent,
      previewTransaction,
      executeTransaction,
      reset,
      hydrateMarketData,
    ],
  )
}
