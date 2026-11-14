"use client"

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { trackEvent } from "@/app/lib/analytics/track-event"
import { usePathname } from "next/navigation"
import { useConvex, useMutation, useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import type { SwapQuote, SwapQuoteRequest } from "@/app/lib/swap-system/quote-provider"
import type { SandboxActionResult } from "@/app/lib/borrow-system/contracts"
import type { LendSandboxActionResult, LendTransactionResult } from "@/app/lib/lend-system/contracts"
import {
  borrowResultToRecordArgs,
  lendResultToRecordArgs,
  swapRecordToRecordSwapArgs,
} from "@/app/lib/sandbox-tx/persistence"
import type { SwapTransactionRecord } from "@/app/lib/swap-system/transaction-adapter"
import type { ConvexUmbrellaSessionState, PersistUmbrellaAction } from "@/app/lib/umbrella-system/use-umbrella-session"
import {
  AvanaSessionsProvider,
  useBorrowSessionContext,
  useLendSessionContext,
  useSwapSessionContext,
} from "./avana-sessions-provider"
import { ConvexMarketSnapshotHydrators } from "./convex-market-snapshot-hydrators"
import { resolveProductRuntimeScope, type ProductRuntimeScope } from "./product-runtime-scope"
import { pendingHydrationIntentIds, shouldApplyHydration } from "./wallet-hydration-guard"
import {
  advanceRevisionOnSuccess,
  captureHydratedRevisions,
  seedRevisionFromReceipt,
  withExpectedRevision,
  type PositionRevisionSummary,
} from "./optimistic-revision"

type EnsureWalletFixture = (args: { wallet: string }) => Promise<unknown>

export function useEnsureWalletFixtures({
  walletId,
  ensurePortfolioSnapshot,
  ensureUmbrellaFixtures,
  retryDelayMs = 1_000,
  maxAttempts = 3,
}: {
  walletId: string
  ensurePortfolioSnapshot: EnsureWalletFixture
  ensureUmbrellaFixtures: EnsureWalletFixture
  retryDelayMs?: number
  maxAttempts?: number
}) {
  const ensuredWalletRef = useRef<string | null>(null)
  const attemptsByWalletRef = useRef(new Map<string, number>())
  const [ensureAttempt, setEnsureAttempt] = useState(0)

  useEffect(() => {
    if (ensuredWalletRef.current === walletId) return
    let cancelled = false
    let retryTimer: ReturnType<typeof setTimeout> | undefined
    ensuredWalletRef.current = walletId
    const attempt = (attemptsByWalletRef.current.get(walletId) ?? 0) + 1
    attemptsByWalletRef.current.set(walletId, attempt)
    void (async () => {
      try {
        await ensurePortfolioSnapshot({ wallet: walletId })
        await ensureUmbrellaFixtures({ wallet: walletId })
        attemptsByWalletRef.current.delete(walletId)
      } catch {
        if (cancelled || ensuredWalletRef.current !== walletId) return
        if (attempt >= maxAttempts) return
        ensuredWalletRef.current = null
        retryTimer = setTimeout(
          () => setEnsureAttempt((currentAttempt) => currentAttempt + 1),
          retryDelayMs * 2 ** (attempt - 1),
        )
      }
    })()
    return () => {
      cancelled = true
      if (retryTimer) clearTimeout(retryTimer)
    }
  }, [ensureAttempt, ensurePortfolioSnapshot, ensureUmbrellaFixtures, maxAttempts, retryDelayMs, walletId])
}

export function useWalletHydrationScope(walletId: string) {
  const revisionScopeRef = useRef<{ walletId: string; revisions: Map<string, number> } | null>(null)
  if (revisionScopeRef.current?.walletId !== walletId) {
    revisionScopeRef.current = { walletId, revisions: new Map() }
  }
  const revisions = revisionScopeRef.current.revisions
  const [hydratedWalletId, setHydratedWalletId] = useState<string | null>(null)
  const handleWalletHydrated = useCallback(
    (positions: readonly PositionRevisionSummary[]) => {
      captureHydratedRevisions(revisions, positions)
      setHydratedWalletId(walletId)
    },
    [revisions, walletId],
  )

  return {
    revisions,
    walletHydrationPending: hydratedWalletId !== walletId,
    handleWalletHydrated,
  }
}

/**
 * Returns the previous reference while `value` is structurally equal, so an effect keyed on it
 * re-runs only when the content changes. Convex hands back a fresh object on every result, even
 * when only a sibling field moved.
 */
function useContentStable<T>(value: T): T {
  const ref = useRef<{ value: T; key: string } | null>(null)
  const key = value === undefined ? "" : JSON.stringify(value)
  if (!ref.current || ref.current.key !== key) ref.current = { value, key }
  return ref.current.value
}

export function ConvexWalletHydrators({
  walletId,
  scope,
  onWalletHydrated,
}: {
  walletId: string
  scope: ProductRuntimeScope
  onWalletHydrated: (positions: readonly PositionRevisionSummary[]) => void
}) {
  const borrow = useBorrowSessionContext()
  const lend = useLendSessionContext()
  const swap = useSwapSessionContext()
  const ensurePortfolioSnapshot = useMutation(api.sandbox.transactions.ensurePortfolioSnapshot)
  const ensureUmbrellaFixtures = useMutation(api.sandbox.umbrella.ensureTestWalletFixtures)
  const walletArgs = scope.walletSession ? { wallet: walletId } : "skip"
  const balances = useQuery(api.sandbox.transactions.getSessionBalances, walletArgs)
  const transactions = useQuery(api.sandbox.transactions.getSessionTransactions, walletArgs)
  // Convex batches subscriptions to a consistent database snapshot. Preserve the
  // full history contract and optimistic intent guard while separating read dependencies.
  const session = useMemo(
    () => (balances && transactions ? { ...balances, transactions } : undefined),
    [balances, transactions],
  )
  const productBalances = useQuery(api.wallet.productBalances.listForWallet, walletArgs)
  const historiesRef = useRef({
    borrow: borrow.transactionHistory,
    lend: lend.transactionHistory,
  })
  historiesRef.current = {
    borrow: borrow.transactionHistory,
    lend: lend.transactionHistory,
  }
  // Seed the wallet snapshot (idempotent). Umbrella fixtures only on umbrella/dashboard.
  const noopEnsure = useCallback(async () => undefined, [])
  useEnsureWalletFixtures({
    walletId,
    ensurePortfolioSnapshot: scope.walletSession ? ensurePortfolioSnapshot : noopEnsure,
    ensureUmbrellaFixtures: scope.ensureUmbrellaFixtures ? ensureUmbrellaFixtures : noopEnsure,
  })

  // Each product session rehydrates only when its own inputs change. The 10-minute LP reprice
  // rewrites `productBalances.borrow` for every wallet holding borrow collateral; one shared
  // effect made that rebuild the lend session too (and re-render their trees).
  const liquidRows = useContentStable(productBalances?.liquid)
  const borrowRows = useContentStable(productBalances?.borrow)
  const lendRows = useContentStable(productBalances?.lend)
  const productSession = useMemo(() => {
    if (!session || !liquidRows) return undefined
    type HydratablePosition = (typeof session.positions)[number] & { product: "borrow" | "lend" }
    type HydratableTransaction = (typeof session.transactions)[number] & {
      product: "borrow" | "lend" | "rewards" | "swap"
    }
    return {
      ...session,
      // Product balances are the canonical wallet source for all action surfaces.
      // The legacy sandbox session balance query can contain only a partial starter
      // basket, which caused Dashboard to show eight assets while Lend Deposit showed
      // only the stale GHO row.
      balances: liquidRows.map((row) => ({
        assetId: row.assetId,
        symbol: row.symbol,
        amount: row.amount,
        valueUsd: row.valueUsd,
      })),
      positions: session.positions.filter((position) => position.product !== "umbrella") as HydratablePosition[],
      transactions: session.transactions.filter(
        (transaction) => transaction.product !== "umbrella",
      ) as HydratableTransaction[],
    }
  }, [session, liquidRows])
  const canApplyHydration = useCallback(() => {
    if (!session) return false
    const { borrow: borrowHistory, lend: lendHistory } = historiesRef.current
    const pending = pendingHydrationIntentIds([...borrowHistory, ...lendHistory], Date.now())
    return shouldApplyHydration(session, pending)
  }, [session])

  useEffect(() => {
    if (!productSession || !borrowRows || !canApplyHydration()) return
    borrow.hydrateWalletData({
      ...productSession,
      borrowBalances: borrowRows.map((row) => ({
        marketId: row.marketId,
        assetId: row.assetId,
        poolId: row.poolId,
        symbol: row.symbol,
        amount: row.amount,
        valueUsd: row.valueUsd,
        state: row.state,
      })),
    })
  }, [borrow.hydrateWalletData, canApplyHydration, productSession, borrowRows])

  useEffect(() => {
    if (!productSession || !lendRows || !canApplyHydration()) return
    lend.hydrateWalletData({
      ...productSession,
      lendBalances: lendRows.map((row) => ({
        marketId: row.marketId,
        assetId: row.assetId,
        symbol: row.symbol,
        amount: row.amount,
        valueUsd: row.valueUsd,
        state: row.state,
        updatedAt: row.updatedAt,
      })),
    })
  }, [lend.hydrateWalletData, canApplyHydration, productSession, lendRows])

  // Declared after the hydrators so it runs after them in the same commit.
  useEffect(() => {
    if (!session || !productSession || !borrowRows || !lendRows || !canApplyHydration()) return
    onWalletHydrated(session.positions)
  }, [onWalletHydrated, canApplyHydration, session, productSession, borrowRows, lendRows])

  useEffect(() => {
    if (productBalances?.liquid && productBalances.liquid.length > 0) {
      swap.hydrateBalances(
        productBalances.liquid.map((row) => ({
          id: `${walletId}:${row.assetId}:liquid`,
          walletId,
          assetId: row.assetId,
          amount: row.amount,
          sourceType: "wallet" as const,
        })),
      )
      return
    }
    if (productBalances?.liquid) swap.hydrateBalances([])
  }, [productBalances?.liquid, swap.hydrateBalances, walletId])

  return null
}

export function ConvexAvanaSessionsProvider({ walletId, children }: { walletId: string; children: ReactNode }) {
  const pathname = usePathname()
  const scope = resolveProductRuntimeScope(pathname)
  const recordTransaction = useMutation(api.sandbox.transactions.recordTransaction)
  const recordSwap = useMutation(api.sandbox.transactions.recordSwap)
  const durableSwapTransactions = useQuery(
    api.sandbox.transactions.getWalletSwapTransactions,
    scope.swapTransactions ? { wallet: walletId } : "skip",
  )
  const saveRewardsState = useMutation(api.sandbox.rewards.saveState)
  const rewardsState = useQuery(api.sandbox.rewards.getState, scope.rewards ? { wallet: walletId } : "skip")
  const umbrellaSessionState = useQuery(
    api.sandbox.umbrella.getSessionState,
    scope.umbrella ? { wallet: walletId } : "skip",
  )
  const recordUmbrellaAction = useMutation(api.sandbox.umbrella.recordAction)
  const { revisions, walletHydrationPending, handleWalletHydrated } = useWalletHydrationScope(walletId)

  const persistBorrowTransaction = useCallback(
    async (result: SandboxActionResult) => {
      const { args, key } = withExpectedRevision(borrowResultToRecordArgs(result, walletId), "borrow", revisions)
      const persisted = await recordTransaction(args)
      if (persisted.receipt.status === "success") trackEvent("transaction_success", { product: "borrow" })
      if (persisted.revision != null) seedRevisionFromReceipt(revisions, key, persisted.revision)
      else advanceRevisionOnSuccess(revisions, key, persisted.idempotent)
      return {
        id: String(persisted.receipt.id),
        hash: persisted.receipt.hash,
        status: persisted.receipt.status,
        simulated: persisted.receipt.simulated,
        timestamp: persisted.receipt.timestamp,
      }
    },
    [recordTransaction, revisions, walletId],
  )
  const persistLendTransaction = useCallback(
    async (result: LendSandboxActionResult): Promise<LendTransactionResult> => {
      const { args, key } = withExpectedRevision(lendResultToRecordArgs(result, walletId), "lend", revisions)
      const persisted = await recordTransaction(args)
      if (persisted.receipt.status === "success") trackEvent("transaction_success", { product: "lend" })
      if (persisted.revision != null) seedRevisionFromReceipt(revisions, key, persisted.revision)
      else advanceRevisionOnSuccess(revisions, key, persisted.idempotent)
      return {
        id: String(persisted.receipt.id),
        hash: persisted.receipt.hash,
        status: persisted.receipt.status,
        actionType: result.receipt.actionType,
        simulated: persisted.receipt.simulated,
        timestamp: persisted.receipt.timestamp,
      }
    },
    [recordTransaction, revisions, walletId],
  )
  const persistRewardsState = useCallback(
    (args: { stateJson: string; expectedRevision?: number }) =>
      saveRewardsState({ wallet: walletId, stateJson: args.stateJson, expectedRevision: args.expectedRevision }),
    [saveRewardsState, walletId],
  )
  const persistSwapTransaction = useCallback(
    async (record: SwapTransactionRecord) => {
      const args = swapRecordToRecordSwapArgs(record, walletId)
      if (!args) return
      await recordSwap(args)
      trackEvent("transaction_success", { product: "swap" })
    },
    [recordSwap, walletId],
  )
  const convex = useConvex()
  const serverGetSwapQuote = useCallback(
    async (request: SwapQuoteRequest): Promise<SwapQuote> => {
      const quote = await convex.query(api.sandbox.swap.getQuote, {
        wallet: walletId,
        inputAssetId: request.inputAssetId,
        outputAssetId: request.outputAssetId,
        inputAmount: request.inputAmount,
        slippageBps: request.slippageBps,
      })
      return quote as unknown as SwapQuote
    },
    [convex, walletId],
  )
  const persistUmbrellaAction = useCallback<PersistUmbrellaAction>(
    (args) => recordUmbrellaAction({ wallet: walletId, ...args }),
    [recordUmbrellaAction, walletId],
  )
  const remoteUmbrellaState: ConvexUmbrellaSessionState | null | undefined = !scope.umbrella
    ? null
    : umbrellaSessionState === undefined
      ? undefined
      : (umbrellaSessionState as unknown as ConvexUmbrellaSessionState)
  const remoteRewardsState = !scope.rewards
    ? null
    : (rewardsState?.stateJson ?? (rewardsState === null ? null : undefined))
  // Missing `revision` on legacy rows matches server (`existing.revision ?? 0`).
  const remoteRewardsRevision = !scope.rewards
    ? null
    : rewardsState === undefined
      ? undefined
      : rewardsState === null
        ? null
        : (rewardsState.revision ?? 0)
  const remoteSwapTransactions = !scope.swapTransactions ? [] : (durableSwapTransactions ?? undefined)
  return (
    <AvanaSessionsProvider
      walletId={walletId}
      // Scope-gate every Convex writer. A skipped query forces remote=null/[] while the
      // session hook still looks "hydrated"; an ungated persist then writes without OCC
      // context (REVISION_REQUIRED) or against empty local state. Same class of bug as
      // rewards saveState on `/` → `/dashboard`.
      persistBorrowTransaction={scope.walletSession ? persistBorrowTransaction : undefined}
      persistLendTransaction={scope.walletSession ? persistLendTransaction : undefined}
      persistSwapTransaction={scope.swapTransactions ? persistSwapTransaction : undefined}
      serverGetSwapQuote={scope.swapTransactions ? serverGetSwapQuote : undefined}
      remoteSwapTransactions={remoteSwapTransactions}
      remoteRewardsState={remoteRewardsState}
      remoteRewardsRevision={remoteRewardsRevision}
      persistRewardsState={scope.rewards ? persistRewardsState : undefined}
      persistLocalState={false}
      remoteUmbrellaState={remoteUmbrellaState}
      persistUmbrellaAction={scope.umbrella ? persistUmbrellaAction : undefined}
      persistUmbrellaState={false}
      sessionSource="convex"
      authoritativeWalletPending={scope.walletSession ? walletHydrationPending : false}
    >
      <ConvexMarketSnapshotHydrators scope={scope} />
      <ConvexWalletHydrators walletId={walletId} scope={scope} onWalletHydrated={handleWalletHydrated} />
      {children}
    </AvanaSessionsProvider>
  )
}
