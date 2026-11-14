"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { DEMO_SWAP_BALANCES } from "./wallet-balances"
import { MockSwapProvider, type SwapQuote, type SwapQuoteRequest } from "./quote-provider"
import {
  SandboxSwapTransactionAdapter,
  type SwapExecutionOptions,
  type SwapSystemState,
  type SwapTransactionRecord,
} from "./transaction-adapter"
import type { UserAssetBalance } from "./contracts"
import { readSwapSessionState, swapSessionStorageKey, writeSwapSessionState } from "./storage"

const SERVER_QUOTE_TIMEOUT_MS = 4_000

async function withServerQuoteTimeout(quotePromise: Promise<SwapQuote>): Promise<SwapQuote> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      quotePromise,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error("Swap quote request timed out.")), SERVER_QUOTE_TIMEOUT_MS)
      }),
    ])
  } finally {
    if (timeout) clearTimeout(timeout)
  }
}

/** A swap read back from Convex (`getWalletSwapTransactions`). Durable, cross-device. */
export type DurableSwapTransaction = {
  id: string
  intentId: string | null
  status: "success" | "failed" | "pending"
  inputSymbol: string
  outputSymbol: string
  inputAmount: number
  outputAmount: number
  amountUsd: number
  hash: string
  at: number
}

function createInitialSwapSystemState(walletId: string, seedDemoBalances: boolean): SwapSystemState {
  if (!seedDemoBalances) return { balances: [], allowances: {}, transactions: [] }
  const seededBalances = DEMO_SWAP_BALANCES.filter((balance) => balance.walletId === "demo-wallet").map((balance) => ({
    ...balance,
    id: balance.id.replace("demo-wallet", walletId),
    walletId,
  }))

  return {
    balances: seededBalances,
    allowances: {},
    transactions: [],
  }
}

export function useSwapSession({
  walletId,
  persistState = true,
  persistTransaction,
  serverGetQuote,
  remoteTransactions,
  seedDemoBalances = true,
}: {
  walletId: string
  persistState?: boolean
  /** Seed the local-test demo balances. False for Convex sessions: balances come only from Convex
   *  (none for a guest). */
  seedDemoBalances?: boolean
  /**
   * Durable server persistence for an executed swap (Convex mode), called after the local adapter
   * applies it. Failures are swallowed: the local session already reflects the swap.
   */
  persistTransaction?: (record: SwapTransactionRecord) => void | Promise<unknown>
  /**
   * Server-authoritative quote source (Convex mode) — the SAME engine recordSwap executes with, so
   * the preview matches the swap. Undefined in demo mode, which uses the local MockSwapProvider.
   */
  serverGetQuote?: (request: SwapQuoteRequest) => Promise<SwapQuote>
  /**
   * Durable swaps read back from Convex, exposed as `durableTransactions` so the dashboard can
   * merge them with the in-session history (deduped by swap id) after a reload or on a new device.
   */
  remoteTransactions?: DurableSwapTransaction[]
}) {
  const seededState = useMemo(
    () => createInitialSwapSystemState(walletId, seedDemoBalances),
    [seedDemoBalances, walletId],
  )
  const [state, setState] = useState<SwapSystemState>(seededState)
  const [hydratedWalletId, setHydratedWalletId] = useState<string | null>(null)
  const stateRef = useRef(state)
  const revisionRef = useRef(0)
  const writingRef = useRef(false)
  stateRef.current = state

  useEffect(() => {
    const hydrated = persistState ? readSwapSessionState(walletId, seededState) : { ...seededState, revision: 0 }
    setState(hydrated)
    revisionRef.current = hydrated.revision
    setHydratedWalletId(walletId)
  }, [persistState, seededState, walletId])

  useEffect(() => {
    if (!persistState || hydratedWalletId !== walletId) return
    // Suppress same-tab reload while we persist — writeSwapSessionState notifies
    // synchronously, and echoing that into setState would loop forever.
    writingRef.current = true
    const persisted = writeSwapSessionState(walletId, state, revisionRef.current)
    revisionRef.current = persisted.revision
    queueMicrotask(() => {
      writingRef.current = false
    })
  }, [hydratedWalletId, persistState, state, walletId])

  useEffect(() => {
    if (!persistState || typeof window === "undefined") return undefined
    const reload = () => {
      if (writingRef.current) return
      const next = readSwapSessionState(walletId, seededState)
      if (next.revision === revisionRef.current) return
      revisionRef.current = next.revision
      setState(next)
    }
    const handleStorage = (event: StorageEvent) => {
      if (event.key === swapSessionStorageKey(walletId)) reload()
    }
    const handleSameTab = (event: Event) => {
      const detail = (event as CustomEvent<{ walletId?: string }>).detail
      if (detail?.walletId === walletId) reload()
    }
    window.addEventListener("storage", handleStorage)
    window.addEventListener("avana:swap-session-updated", handleSameTab)
    return () => {
      window.removeEventListener("storage", handleStorage)
      window.removeEventListener("avana:swap-session-updated", handleSameTab)
    }
  }, [persistState, seededState, walletId])

  const adapter = useMemo(
    () =>
      new SandboxSwapTransactionAdapter({
        readState: () => stateRef.current,
        writeState: (next) => {
          stateRef.current = next
          setState(next)
        },
        provider: new MockSwapProvider(),
      }),
    [],
  )

  const walletBalances = useMemo(
    () => state.balances.filter((balance): balance is UserAssetBalance => balance.walletId === walletId),
    [state.balances, walletId],
  )

  const getQuote = useCallback(
    (request: Omit<SwapQuoteRequest, "walletId">) => {
      const full = { ...request, walletId }
      // Server engine (Convex) is authoritative when available; the local provider is the
      // demo-mode fallback (same engine math, static catalog prices).
      return serverGetQuote ? withServerQuoteTimeout(serverGetQuote(full)) : adapter.provider.getQuote(full)
    },
    [adapter, serverGetQuote, walletId],
  )
  const getIndicativeQuote = useCallback(
    (request: Omit<SwapQuoteRequest, "walletId">) => adapter.provider.getQuote({ ...request, walletId }),
    [adapter, walletId],
  )
  const requiresApproval = useCallback(
    (assetId: string, amount: number) => adapter.requiresApproval(walletId, assetId, amount),
    [adapter, walletId],
  )
  const approve = useCallback(
    (assetId: string, amount: number, options?: SwapExecutionOptions) =>
      adapter.approve(walletId, assetId, amount, options),
    [adapter, walletId],
  )
  const executeSwap = useCallback(
    async (quote: Parameters<typeof adapter.executeSwap>[0], options?: SwapExecutionOptions) => {
      const record = await adapter.executeSwap(quote, walletId, options)
      if (persistTransaction) {
        try {
          await persistTransaction(record)
        } catch {
          // Best-effort: the local session already reflects the swap; a failed durable
          // write must not surface as a swap failure to the user.
        }
      }
      return record
    },
    [adapter, persistTransaction, walletId],
  )

  const hydrateBalances = useCallback(
    (balances: UserAssetBalance[]) => {
      setState((current) => ({
        ...current,
        balances: balances.map((balance) => ({
          ...balance,
          walletId: balance.walletId || walletId,
        })),
      }))
    },
    [walletId],
  )

  const isHydrated = hydratedWalletId === walletId
  const transactionHistory = state.transactions
  /** Durable swaps from Convex (empty in demo mode); the dashboard merges these with the
   *  in-session history, deduped by swap id. */
  const durableTransactions = remoteTransactions ?? EMPTY_DURABLE_TRANSACTIONS

  return useMemo(
    () => ({
      walletId,
      isHydrated,
      state,
      walletBalances,
      transactionHistory,
      durableTransactions,
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
      durableTransactions,
      getQuote,
      getIndicativeQuote,
      requiresApproval,
      approve,
      executeSwap,
      hydrateBalances,
    ],
  )
}

const EMPTY_DURABLE_TRANSACTIONS: DurableSwapTransaction[] = []
