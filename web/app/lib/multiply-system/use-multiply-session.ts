"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import type { MultiplyAction, MultiplySystemState } from "@/app/lib/multiply-engine"
import { revalueMultiplyPosition } from "@/app/lib/multiply-engine"
import { deserializeMultiplySystemState, serializeMultiplySystemState } from "./codec"
import type {
  MultiplyReadAdapter,
  MultiplySandboxActionResult,
  MultiplyTransactionAdapter,
  MultiplyTransactionHistoryItem,
  MultiplyTransactionIntent,
  MultiplyTransactionResult,
} from "./contracts"
import { buildSyntheticReceipts, inferOpenedLeverageByMarket } from "./read-model"
import { SandboxMultiplyReadAdapter } from "./sandbox-read-adapter"
import { SandboxMultiplyTransactionAdapter } from "./sandbox-transaction-adapter"
import { mergeConvexMultiplySnapshots, type MultiplyConvexSnapshot } from "./market-hydration"
import {
  clearMultiplySessionState,
  readMultiplySessionMetadata,
  readMultiplySessionState,
  writeMultiplySessionMetadata,
  writeMultiplySessionState,
} from "./storage"
import { MULTIPLY_SESSION_SYNC_EVENT } from "./session-sync"
import { isLegacySeedOnlyMultiplyState } from "./mock"
import { deriveMultiplyCollateralBudgetUsd } from "./wallet-collateral-budget"

function mergeHistory(nextItem: MultiplyTransactionHistoryItem, history: MultiplyTransactionHistoryItem[]) {
  return [nextItem, ...history.filter((item) => item.id !== nextItem.id)]
}

function mergeReceipts(nextReceipt: MultiplyTransactionResult, receipts: MultiplyTransactionResult[]) {
  return [nextReceipt, ...receipts.filter((receipt) => receipt.id !== nextReceipt.id)]
}

type ConvexMultiplyWalletData = {
  positions: Array<{
    _id: string
    product: "borrow" | "lend" | "multiply"
    marketSlug: string
    status: "open" | "closed"
    collateralAmount?: number
    collateralValueUsd?: number
    debtValueUsd?: number
    multiplier?: number
    ltv?: number
    healthFactor?: number | "infinity"
    liquidationPrice?: number | null
    netApyPct?: number
    openedAt: number
    lastUpdatedAt: number
  }>
  transactions: Array<{
    _id: string
    intentId?: string
    product: "borrow" | "lend" | "multiply" | "swap" | "rewards"
    kind: string
    status: "success" | "failed" | "pending"
    marketSlug?: string
    positionId?: string | null
    amountUsd: number
    multiplierBefore?: number
    multiplierAfter?: number
    syntheticTxHash: string
    simulated: boolean
    at: number
  }>
  multiplyBalances?: Array<{
    marketId?: string
    assetId: string
    symbol: string
    amount: number
    valueUsd: number
    state: "available" | "collateral" | "debt" | "position"
  }>
  // Real liquid token holdings (walletLiquidBalances), used to derive an "available" collateral
  // budget for markets with no explicit multiplyBalances row so they aren't stuck at "Max 0".
  balances?: Array<{
    symbol: string
    valueUsd: number
    amount?: number
  }>
}

export function useMultiplySession({
  walletId,
  sessionSeed,
  readAdapter: injectedReadAdapter,
  transactionAdapter: injectedTransactionAdapter,
  persistState,
  persistTransaction,
}: {
  walletId: string
  sessionSeed: string
  readAdapter?: MultiplyReadAdapter
  transactionAdapter?: MultiplyTransactionAdapter
  persistState?: boolean
  persistTransaction?: (result: MultiplySandboxActionResult) => Promise<MultiplyTransactionResult>
}) {
  const adapterMode = injectedReadAdapter?.mode ?? injectedTransactionAdapter?.mode ?? "sandbox"
  const shouldPersistState = persistState ?? adapterMode === "sandbox"
  const seededState = useMemo(() => deserializeMultiplySystemState(sessionSeed), [sessionSeed])
  const [state, setState] = useState<MultiplySystemState>(seededState)
  const [hasHydratedStorage, setHasHydratedStorage] = useState(false)
  const [hydratedWalletId, setHydratedWalletId] = useState<string | null>(null)
  const [transactionHistory, setTransactionHistory] = useState<MultiplyTransactionHistoryItem[]>(
    () => readMultiplySessionMetadata(walletId).transactionHistory,
  )
  const [transactionReceipts, setTransactionReceipts] = useState<MultiplyTransactionResult[]>(() =>
    buildSyntheticReceipts(readMultiplySessionMetadata(walletId).transactionHistory),
  )
  const stateRef = useRef(state)
  stateRef.current = state
  const isPersistingRef = useRef(false)
  const lastPersistedStateRef = useRef<string | null>(null)
  const lastPersistedMetadataRef = useRef<string | null>(null)
  const inFlightRef = useRef(0)
  const [isPending, setIsPending] = useState(false)

  useEffect(() => {
    if (!shouldPersistState) {
      setState(seededState)
      setTransactionHistory([])
      setTransactionReceipts([])
      setHasHydratedStorage(true)
      setHydratedWalletId(walletId)
      return
    }
    const persistedState = readMultiplySessionState(walletId, sessionSeed)
    const metadata = readMultiplySessionMetadata(walletId)
    const nextState =
      metadata.transactionHistory.length === 0 && isLegacySeedOnlyMultiplyState(persistedState, walletId)
        ? seededState
        : persistedState
    lastPersistedStateRef.current = serializeMultiplySystemState(nextState)
    lastPersistedMetadataRef.current = JSON.stringify({
      transactionHistory: metadata.transactionHistory,
      receipts: metadata.receipts,
    })
    setState(nextState)
    setTransactionHistory(metadata.transactionHistory)
    setTransactionReceipts(
      metadata.receipts.length > 0 ? metadata.receipts : buildSyntheticReceipts(metadata.transactionHistory),
    )
    setHasHydratedStorage(true)
    setHydratedWalletId(walletId)
  }, [seededState, sessionSeed, shouldPersistState, walletId])

  useEffect(() => {
    if (!shouldPersistState || !hasHydratedStorage) return
    const serializedState = serializeMultiplySystemState(state)
    if (serializedState === lastPersistedStateRef.current) return
    isPersistingRef.current = true
    lastPersistedStateRef.current = serializedState
    writeMultiplySessionState(walletId, state)
    queueMicrotask(() => {
      isPersistingRef.current = false
    })
  }, [hasHydratedStorage, shouldPersistState, walletId, state])

  useEffect(() => {
    if (!shouldPersistState || !hasHydratedStorage) return
    const metadata = {
      transactionHistory,
      receipts: transactionReceipts,
    }
    const serializedMetadata = JSON.stringify(metadata)
    if (serializedMetadata === lastPersistedMetadataRef.current) return
    isPersistingRef.current = true
    lastPersistedMetadataRef.current = serializedMetadata
    writeMultiplySessionMetadata(walletId, metadata)
    queueMicrotask(() => {
      isPersistingRef.current = false
    })
  }, [hasHydratedStorage, shouldPersistState, walletId, transactionHistory, transactionReceipts])

  useEffect(() => {
    if (!shouldPersistState || typeof window === "undefined") return undefined

    const reloadFromStorage = () => {
      const nextState = readMultiplySessionState(walletId, sessionSeed)
      const metadata = readMultiplySessionMetadata(walletId)
      const serializedState = serializeMultiplySystemState(nextState)
      const serializedMetadata = JSON.stringify({
        transactionHistory: metadata.transactionHistory,
        receipts: metadata.receipts,
      })
      if (
        serializedState === lastPersistedStateRef.current &&
        serializedMetadata === lastPersistedMetadataRef.current
      ) {
        return
      }
      lastPersistedStateRef.current = serializedState
      lastPersistedMetadataRef.current = serializedMetadata
      setState(nextState)
      setTransactionHistory(metadata.transactionHistory)
      setTransactionReceipts(
        metadata.receipts.length > 0 ? metadata.receipts : buildSyntheticReceipts(metadata.transactionHistory),
      )
    }

    const handleStorage = (event: StorageEvent) => {
      if (event.key == null || !event.key.endsWith(`:${walletId}`)) return
      reloadFromStorage()
    }

    const handleSameTabSync = (event: Event) => {
      const detail = (event as CustomEvent<{ walletId: string }>).detail
      if (detail?.walletId !== walletId || isPersistingRef.current) return
      reloadFromStorage()
    }

    window.addEventListener("storage", handleStorage)
    window.addEventListener(MULTIPLY_SESSION_SYNC_EVENT, handleSameTabSync)
    return () => {
      window.removeEventListener("storage", handleStorage)
      window.removeEventListener(MULTIPLY_SESSION_SYNC_EVENT, handleSameTabSync)
    }
  }, [sessionSeed, shouldPersistState, walletId])

  const transactionAdapter = useMemo(() => {
    if (injectedTransactionAdapter) return injectedTransactionAdapter
    return new SandboxMultiplyTransactionAdapter({
      readState: () => stateRef.current,
      writeState: (nextState) => {
        stateRef.current = nextState
        setState(nextState)
      },
      persistResult: persistTransaction,
    })
  }, [injectedTransactionAdapter, persistTransaction])

  const readAdapter = useMemo(
    () => injectedReadAdapter ?? new SandboxMultiplyReadAdapter({ state, transactionHistory }),
    [injectedReadAdapter, state, transactionHistory],
  )

  const hydrateMarketData = useCallback((snapshots: readonly MultiplyConvexSnapshot[]) => {
    setState((prev) => mergeConvexMultiplySnapshots(prev, snapshots))
  }, [])

  const hydrateWalletData = useCallback(
    (data: ConvexMultiplyWalletData) => {
      const positions: Record<string, MultiplySystemState["positions"][string]> = {}
      const explicitBucketsUsd: Record<string, number> = {}
      for (const row of data.multiplyBalances ?? []) {
        if (row.state !== "available") continue
        const marketId = row.marketId ?? row.assetId
        explicitBucketsUsd[marketId] = (explicitBucketsUsd[marketId] ?? 0) + row.valueUsd
      }
      const liquidHoldings = data.balances ?? []
      for (const position of data.positions) {
        if (position.product !== "multiply" || position.status !== "open") continue
        const id = String(position._id)
        positions[id] = {
          id,
          walletId,
          marketId: position.marketSlug,
          collateralAmount: position.collateralAmount ?? 0,
          collateralValueUsd: position.collateralValueUsd ?? 0,
          debtValueUsd: position.debtValueUsd ?? 0,
          multiplier: position.multiplier ?? 1,
          ltv: position.ltv ?? 0,
          healthFactor: position.healthFactor ?? "infinity",
          liquidationPrice: position.liquidationPrice ?? null,
          netApy: position.netApyPct ?? 0,
          openedAt: position.openedAt,
          lastUpdatedAt: position.lastUpdatedAt,
        }
      }
      // Resolve the resulting multiplier by POSITION, not tx id — position ids never equal
      // `transaction._id`. Prefer the linked positionId, else the still-open position for the
      // market. The inferred-open map below covers positions that have since closed, whose
      // position row is gone and would otherwise read "1.00x → 1.00x".
      const positionByMarket = new Map(Object.values(positions).map((position) => [position.marketId, position]))
      const openedLeverageByMarket = inferOpenedLeverageByMarket(data.transactions)
      const history: MultiplyTransactionHistoryItem[] = data.transactions
        .filter((transaction) => transaction.product === "multiply")
        .map((transaction) => {
          const position =
            (transaction.positionId ? positions[String(transaction.positionId)] : undefined) ??
            (transaction.marketSlug ? positionByMarket.get(transaction.marketSlug) : undefined)
          // For an open, the resulting leverage is the opened multiplier: persisted value, else the
          // still-open position, else inferred from a later unwind on the same market, else 1.
          const inferredOpenLeverage = transaction.marketSlug
            ? openedLeverageByMarket.get(transaction.marketSlug)
            : undefined
          const openMultiplierAfter = transaction.multiplierAfter ?? position?.multiplier ?? inferredOpenLeverage ?? 1
          return {
            id: String(transaction._id),
            intentId: transaction.intentId ?? String(transaction._id),
            walletId,
            marketId: transaction.marketSlug ?? position?.marketId,
            positionId: position?.id,
            kind: transaction.kind as MultiplyTransactionHistoryItem["kind"],
            status: transaction.status,
            amountUsd: transaction.amountUsd,
            // Use the leverage captured AT the transaction; the fallbacks cover legacy rows
            // written before multiplierBefore/After were persisted.
            multiplierBefore: transaction.multiplierBefore ?? 1,
            multiplierAfter:
              transaction.kind === "multiply"
                ? openMultiplierAfter
                : (transaction.multiplierAfter ?? position?.multiplier ?? 1),
            simulated: transaction.simulated,
            timestamp: transaction.at,
            hash: transaction.syntheticTxHash,
          }
        })
      // Re-derive USD figures from collateralAmount × current price; persisted values freeze at
      // write time. Falls back to persisted when the market price is unavailable.
      setState((current) => {
        const revalued: typeof positions = {}
        for (const [id, position] of Object.entries(positions)) {
          const market = current.markets[position.marketId]
          revalued[id] = market ? revalueMultiplyPosition(position, market) : position
        }
        // Derive here (not above) because the per-market fallback needs each market's
        // collateral symbol, which only exists once market data is hydrated into state.
        const walletBalancesUsd: MultiplySystemState["walletBalancesUsd"] = {
          [walletId]: deriveMultiplyCollateralBudgetUsd({
            explicitBucketsUsd,
            markets: current.markets,
            liquidHoldings,
          }),
        }
        return { ...current, positions: revalued, walletBalancesUsd }
      })
      setTransactionHistory(history)
      setTransactionReceipts(buildSyntheticReceipts(history))
    },
    [walletId],
  )

  const createIntent = useCallback(
    (action: MultiplyAction) => transactionAdapter.createIntent(action),
    [transactionAdapter],
  )

  const previewTransaction = useCallback(
    (intent: MultiplyTransactionIntent) => transactionAdapter.previewTransaction(intent),
    [transactionAdapter],
  )

  const executeTransaction = useCallback(
    async (intent: MultiplyTransactionIntent): Promise<MultiplySandboxActionResult> => {
      inFlightRef.current += 1
      setIsPending(true)
      try {
        const result = await transactionAdapter.executeTransaction(intent)
        stateRef.current = result.state
        setState(result.state)
        setTransactionHistory((current) => mergeHistory(result.historyItem, current))
        setTransactionReceipts((current) => mergeReceipts(result.receipt, current))
        return result
      } finally {
        inFlightRef.current -= 1
        setIsPending(inFlightRef.current > 0)
      }
    },
    [transactionAdapter],
  )

  const reset = useCallback(() => {
    if (shouldPersistState) clearMultiplySessionState(walletId)
    setState(seededState)
    setTransactionHistory([])
    setTransactionReceipts([])
  }, [seededState, shouldPersistState, walletId])

  const isHydrated = hasHydratedStorage && hydratedWalletId === walletId

  return useMemo(
    () => ({
      walletId,
      state,
      readAdapter,
      transactionHistory,
      transactionReceipts,
      hydrateMarketData,
      hydrateWalletData,
      createIntent,
      previewTransaction,
      executeTransaction,
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
      hydrateWalletData,
      createIntent,
      previewTransaction,
      executeTransaction,
      reset,
      isPending,
      isHydrated,
    ],
  )
}
