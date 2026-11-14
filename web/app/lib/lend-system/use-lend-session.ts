"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import type { LendAction, LendSystemState } from "@/app/lib/lend-engine"
import { accrueLendSystemState } from "@/app/lib/lend-engine/simulation"
import { calculateScaledDepositAmount } from "@/app/lib/lend-engine/formulas"
import { deserializeLendSystemState, serializeLendSystemState } from "./codec"
import type {
  LendReadAdapter,
  LendSandboxActionResult,
  LendTransactionAdapter,
  LendTransactionHistoryItem,
  LendTransactionIntent,
  LendTransactionResult,
} from "./contracts"
import { SandboxLendReadAdapter } from "./sandbox-read-adapter"
import { SandboxLendTransactionAdapter } from "./sandbox-transaction-adapter"
import { mergeConvexLendSnapshots, type LendConvexSnapshot } from "./market-hydration"
import { resolveLendMarketId } from "./catalog"
import {
  clearLendSessionState,
  readLendSessionMetadata,
  readLendSessionState,
  writeLendSessionMetadata,
  writeLendSessionState,
} from "./storage"
import { LEND_SESSION_SYNC_EVENT } from "./session-sync"

/**
 * Convert a Convex lend position's USD figures into the token amounts the engine state expects.
 * The server stores USD6; `suppliedAmount`/`principalAmount`/`interestEarned` are TOKEN amounts
 * that consumers re-multiply by the price, so dividing by the asset price here is required.
 */
export function deriveLendPositionAmounts(
  suppliedValueUsd: number,
  earnedUsd: number,
  assetPriceUsd: number | undefined,
): { suppliedAmount: number; principalAmount: number; interestEarnedAmount: number } {
  const price = assetPriceUsd && assetPriceUsd > 0 ? assetPriceUsd : 1
  const suppliedAmount = suppliedValueUsd / price
  const interestEarnedAmount = earnedUsd / price
  return {
    suppliedAmount,
    interestEarnedAmount,
    principalAmount: Math.max(0, suppliedAmount - interestEarnedAmount),
  }
}

/** Position amounts from the ledger's deposited token count (earned interest is included in it). */
export function lendAmountsFromTokens(
  depositedTokens: number,
  earnedUsd: number,
  assetPriceUsd: number | undefined,
): { suppliedAmount: number; principalAmount: number; interestEarnedAmount: number } {
  const interestEarnedAmount =
    assetPriceUsd && assetPriceUsd > 0 ? Math.min(depositedTokens, earnedUsd / assetPriceUsd) : 0
  return {
    suppliedAmount: depositedTokens,
    interestEarnedAmount,
    principalAmount: Math.max(0, depositedTokens - interestEarnedAmount),
  }
}

function mergeHistory(nextItem: LendTransactionHistoryItem, history: LendTransactionHistoryItem[]) {
  return [nextItem, ...history.filter((item) => item.id !== nextItem.id)]
}

function mergeReceipts(nextReceipt: LendTransactionResult, receipts: LendTransactionResult[]) {
  return [nextReceipt, ...receipts.filter((receipt) => receipt.id !== nextReceipt.id)]
}

type ConvexLendWalletData = {
  /** Canonical unallocated wallet holdings from wallet.productBalances.listForWallet. */
  balances?: Array<{
    assetId: string
    amount: number
    valueUsd: number
  }>
  lendBalances?: Array<{
    marketId: string
    assetId: string
    symbol: string
    amount: number
    valueUsd: number
    state: "available" | "deposited"
    updatedAt?: number
  }>
  positions: Array<{
    _id: string
    product: "borrow" | "lend" | "multiply"
    marketSlug: string
    status: "open" | "closed"
    suppliedUsd6?: string
    earnedUsd6?: string
    supplyApyPct?: number
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
    amountUsd: number
    /** Tokens moved, recorded by the server for lend deposits and withdrawals. */
    tokenAmount?: number
    syntheticTxHash: string
    simulated: boolean
    at: number
  }>
}

export function useLendSession({
  walletId,
  sessionSeed,
  readAdapter: injectedReadAdapter,
  transactionAdapter: injectedTransactionAdapter,
  persistState,
  persistTransaction,
}: {
  walletId: string
  sessionSeed: string
  readAdapter?: LendReadAdapter
  transactionAdapter?: LendTransactionAdapter
  persistState?: boolean
  persistTransaction?: (result: LendSandboxActionResult) => Promise<LendTransactionResult>
}) {
  const adapterMode = injectedReadAdapter?.mode ?? injectedTransactionAdapter?.mode ?? "sandbox"
  const shouldPersistState = persistState ?? adapterMode === "sandbox"
  const seededState = useMemo(() => deserializeLendSystemState(sessionSeed), [sessionSeed])
  const [state, setState] = useState<LendSystemState>(seededState)
  const [hydratedWalletId, setHydratedWalletId] = useState<string | null>(null)
  const [transactionHistory, setTransactionHistory] = useState<LendTransactionHistoryItem[]>(() =>
    shouldPersistState ? readLendSessionMetadata(walletId).transactionHistory : [],
  )
  const [transactionReceipts, setTransactionReceipts] = useState<LendTransactionResult[]>(() =>
    shouldPersistState ? readLendSessionMetadata(walletId).receipts : [],
  )
  const stateRef = useRef(state)
  stateRef.current = state
  const isPersistingRef = useRef(false)
  // Track what this tab last wrote so a cross-tab `storage` event echoing our own write is
  // ignored; otherwise the 30s accrual tick ping-pongs reloads across every open tab.
  const lastPersistedStateRef = useRef<string | null>(null)
  const lastPersistedMetadataRef = useRef<string | null>(null)
  const inFlightRef = useRef(0)
  const [isPending, setIsPending] = useState(false)

  useEffect(() => {
    if (!shouldPersistState) {
      setState(seededState)
      setTransactionHistory([])
      setTransactionReceipts([])
      setHydratedWalletId(walletId)
      return
    }
    const nextState = readLendSessionState(walletId, sessionSeed)
    const metadata = readLendSessionMetadata(walletId)
    lastPersistedStateRef.current = serializeLendSystemState(nextState)
    lastPersistedMetadataRef.current = JSON.stringify({
      transactionHistory: metadata.transactionHistory,
      receipts: metadata.receipts,
    })
    setState(nextState)
    setTransactionHistory(metadata.transactionHistory)
    setTransactionReceipts(metadata.receipts)
    setHydratedWalletId(walletId)
  }, [seededState, sessionSeed, shouldPersistState, walletId])

  useEffect(() => {
    if (!shouldPersistState) return
    // Skip while state is still the SSR seed (pre-hydration); persisting it here
    // would clobber richer data already in storage before the restore effect runs.
    if (state === seededState) return
    const serializedState = serializeLendSystemState(state)
    // Nothing changed since our last write (e.g. an accrual tick that produced an
    // equivalent state) — don't re-write, so we don't emit a redundant storage event.
    if (serializedState === lastPersistedStateRef.current) return
    isPersistingRef.current = true
    lastPersistedStateRef.current = serializedState
    writeLendSessionState(walletId, state)
    queueMicrotask(() => {
      isPersistingRef.current = false
    })
  }, [shouldPersistState, walletId, state, seededState])

  useEffect(() => {
    if (!shouldPersistState) return
    const serializedMetadata = JSON.stringify({
      transactionHistory,
      receipts: transactionReceipts,
    })
    if (serializedMetadata === lastPersistedMetadataRef.current) return
    isPersistingRef.current = true
    lastPersistedMetadataRef.current = serializedMetadata
    writeLendSessionMetadata(walletId, {
      transactionHistory,
      receipts: transactionReceipts,
    })
    queueMicrotask(() => {
      isPersistingRef.current = false
    })
  }, [shouldPersistState, walletId, transactionHistory, transactionReceipts])

  useEffect(() => {
    if (!shouldPersistState || typeof window === "undefined") return undefined
    if (typeof window === "undefined") return undefined

    const reloadFromStorage = () => {
      const nextState = readLendSessionState(walletId, sessionSeed)
      const metadata = readLendSessionMetadata(walletId)
      const serializedState = serializeLendSystemState(nextState)
      const serializedMetadata = JSON.stringify({
        transactionHistory: metadata.transactionHistory,
        receipts: metadata.receipts,
      })
      // The storage already matches what this tab holds/last wrote — a cross-tab echo of
      // our own accrual write. Re-applying it would re-persist and bounce back to the
      // other tab, so bail before touching state (breaks the 30s ping-pong).
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
      setTransactionReceipts(metadata.receipts)
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
    window.addEventListener(LEND_SESSION_SYNC_EVENT, handleSameTabSync)
    return () => {
      window.removeEventListener("storage", handleStorage)
      window.removeEventListener(LEND_SESSION_SYNC_EVENT, handleSameTabSync)
    }
  }, [sessionSeed, shouldPersistState, walletId])

  useEffect(() => {
    if (!shouldPersistState || typeof window === "undefined" || process.env.NODE_ENV === "test") return undefined

    const tick = () => {
      setState((current) => {
        // Without an active position nothing user-visible accrues, so return the
        // same reference to avoid re-rendering the whole app tree every 30s.
        const hasActivePosition = Object.values(current.positions).some((position) => position.status === "active")
        if (!hasActivePosition) return current
        return accrueLendSystemState(current, Date.now())
      })
    }

    // Only accrue while visible. accrueLendSystemState integrates from each position's
    // lastAccrualTimestamp, so one catch-up tick on refocus recovers everything missed while
    // hidden — no accrual is lost and backgrounded tabs stop spinning the 30s persist loop.
    const tickIfVisible = () => {
      if (document.visibilityState === "visible") tick()
    }

    tickIfVisible()
    const intervalId = window.setInterval(tickIfVisible, 30_000)
    document.addEventListener("visibilitychange", tickIfVisible)
    return () => {
      window.clearInterval(intervalId)
      document.removeEventListener("visibilitychange", tickIfVisible)
    }
  }, [shouldPersistState])

  const transactionAdapter = useMemo(() => {
    if (injectedTransactionAdapter) return injectedTransactionAdapter
    return new SandboxLendTransactionAdapter({
      readState: () => stateRef.current,
      writeState: (nextState) => {
        stateRef.current = nextState
        setState(nextState)
      },
      persistResult: persistTransaction,
    })
  }, [injectedTransactionAdapter, persistTransaction])

  const readAdapter = useMemo(() => {
    if (injectedReadAdapter) return injectedReadAdapter
    return new SandboxLendReadAdapter({ state, transactionHistory })
  }, [injectedReadAdapter, state, transactionHistory])

  const hydrateMarketData = useCallback((snapshots: readonly LendConvexSnapshot[]) => {
    setState((prev) => mergeConvexLendSnapshots(prev, snapshots))
  }, [])

  const hydrateWalletData = useCallback(
    (data: ConvexLendWalletData) => {
      const positions: Record<string, LendSystemState["positions"][string]> = {}
      // Deposited token counts from the server ledger. Dividing the stored USD by whichever
      // price had loaded made the same OP deposit read 25,685 OP on the dashboard and
      // 305,012 OP on Withdraw, and Withdraw let the user take the larger figure.
      const depositedTokensByMarket = new Map<string, number>()
      for (const row of data.lendBalances ?? []) {
        if (row.state !== "deposited" || !(row.amount > 0)) continue
        depositedTokensByMarket.set(row.marketId, (depositedTokensByMarket.get(row.marketId) ?? 0) + row.amount)
      }
      for (const position of data.positions) {
        if (position.product !== "lend") continue
        const market = stateRef.current.markets[position.marketSlug]
        const ledgerSuppliedUsd = Number(BigInt(position.suppliedUsd6 ?? "0")) / 1_000_000
        const depositedTokens =
          position.status === "open" ? depositedTokensByMarket.get(position.marketSlug) : undefined
        const priceUsd = market?.assetPriceUsd && market.assetPriceUsd > 0 ? market.assetPriceUsd : undefined
        const suppliedValueUsd =
          depositedTokens !== undefined && priceUsd !== undefined ? depositedTokens * priceUsd : ledgerSuppliedUsd
        const earnedUsd = Number(BigInt(position.earnedUsd6 ?? "0")) / 1_000_000
        const amounts =
          depositedTokens !== undefined
            ? lendAmountsFromTokens(depositedTokens, earnedUsd, priceUsd)
            : deriveLendPositionAmounts(suppliedValueUsd, earnedUsd, market?.assetPriceUsd)
        const id = String(position._id)
        positions[id] = {
          positionId: id,
          walletId,
          marketId: position.marketSlug,
          asset: market?.asset.symbol ?? position.marketSlug,
          principalAmount: amounts.principalAmount,
          // scaledBalance is the index-normalized principal; the current balance is recovered as
          // scaledBalance × liquidityIndex (calculateCurrentSuppliedBalance). Storing the raw
          // supplied amount here would re-inflate the balance by the index on the next action.
          scaledBalance: calculateScaledDepositAmount(amounts.suppliedAmount, market?.liquidityIndex ?? 1),
          liquidityIndexAtLastAction: market?.liquidityIndex ?? 1,
          currentSuppliedAmount: amounts.suppliedAmount,
          interestEarned: amounts.interestEarnedAmount,
          rewardsEarnedUsd: 0,
          suppliedValueUsd,
          openedAt: position.openedAt,
          updatedAt: position.lastUpdatedAt,
          status: position.status === "open" ? ("active" as const) : ("closed" as const),
        }
      }
      for (const row of data.lendBalances ?? []) {
        if (row.state !== "deposited" || row.amount <= 0) continue
        if (
          Object.values(positions).some(
            (position) => position.marketId === row.marketId && position.status === "active",
          )
        ) {
          continue
        }
        const market = stateRef.current.markets[row.marketId]
        const id = `${walletId}:product:${row.marketId}`
        positions[id] = {
          positionId: id,
          walletId,
          marketId: row.marketId,
          asset: market?.asset.symbol ?? row.symbol,
          principalAmount: row.amount,
          scaledBalance: calculateScaledDepositAmount(row.amount, market?.liquidityIndex ?? 1),
          liquidityIndexAtLastAction: market?.liquidityIndex ?? 1,
          currentSuppliedAmount: row.amount,
          interestEarned: 0,
          rewardsEarnedUsd: 0,
          suppliedValueUsd: row.valueUsd,
          openedAt: row.updatedAt ?? 0,
          updatedAt: row.updatedAt ?? 0,
          status: "active",
        }
      }
      const history: LendTransactionHistoryItem[] = data.transactions
        .filter((transaction) => transaction.product === "lend")
        .map((transaction) => {
          const market = stateRef.current.markets[transaction.marketSlug ?? ""]
          const assetPriceUsd = market?.assetPriceUsd ?? 0
          const kind = transaction.kind as LendTransactionHistoryItem["kind"]
          return {
            id: String(transaction._id),
            intentId: transaction.intentId ?? String(transaction._id),
            walletId,
            marketId: transaction.marketSlug ?? "rewards",
            kind,
            status: transaction.status,
            asset: market?.asset.symbol ?? "",
            // `amount` is a TOKEN quantity (the read-model multiplies it by assetPriceUsd) but the
            // Convex row records USD, so convert back here. Claims are USD and pass through.
            amount:
              kind === "claim"
                ? transaction.amountUsd
                : (transaction.tokenAmount ??
                  (!(assetPriceUsd > 0) ? transaction.amountUsd : transaction.amountUsd / assetPriceUsd)),
            amountUsd: transaction.amountUsd,
            simulated: transaction.simulated,
            timestamp: transaction.at,
            hash: transaction.syntheticTxHash,
          }
        })
      const walletBalances: LendSystemState["walletBalances"] = { [walletId]: {} }
      for (const row of data.balances ?? []) {
        const marketId = resolveLendMarketId(row.assetId)
        if (stateRef.current.markets[marketId]) {
          walletBalances[walletId]![marketId] = row.amount
        }
      }
      for (const row of data.lendBalances ?? []) {
        if (row.state !== "available") continue
        if (walletBalances[walletId]![row.marketId] === undefined) {
          walletBalances[walletId]![row.marketId] = row.amount
        }
      }
      setState((current) => ({ ...current, positions, walletBalances }))
      setTransactionHistory(history)
      setTransactionReceipts(
        history.map((item) => ({
          id: item.id,
          hash: item.hash,
          status: item.status,
          actionType: item.kind,
          simulated: item.simulated,
          timestamp: item.timestamp,
        })),
      )
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
    async (intent: LendTransactionIntent): Promise<LendSandboxActionResult> => {
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

  const claimRewards = useCallback(async () => {
    const intent = transactionAdapter.createIntent({
      type: "claim",
      walletId,
    })
    return executeTransaction(intent)
  }, [executeTransaction, transactionAdapter, walletId])

  const reset = useCallback(() => {
    if (shouldPersistState) {
      clearLendSessionState(walletId)
    }
    setState(seededState)
    setTransactionHistory([])
    setTransactionReceipts([])
  }, [seededState, shouldPersistState, walletId])

  const isHydrated = hydratedWalletId === walletId

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
      hydrateWalletData,
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
