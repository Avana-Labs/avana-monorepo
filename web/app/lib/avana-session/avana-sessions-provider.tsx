"use client"

import { useEffect, useMemo, useRef, useCallback, type ReactNode } from "react"
import { useMarketLiquidity } from "@/app/lib/convex/market-liquidity-provider"
import { useRewardsSession } from "@/app/lib/rewards-system"
import type { SandboxActionResult } from "@/app/lib/borrow-system/contracts"
import type { LendSandboxActionResult, LendTransactionResult } from "@/app/lib/lend-system/contracts"
import { useBorrowSession } from "@/app/lib/borrow-system/use-borrow-session"
import { useLendSession } from "@/app/lib/lend-system/use-lend-session"
import { useSwapSession, type DurableSwapTransaction } from "@/app/lib/swap-system/use-swap-session"
import type { SwapTransactionRecord } from "@/app/lib/swap-system/transaction-adapter"
import type { SwapQuote, SwapQuoteRequest } from "@/app/lib/swap-system/quote-provider"
import { useAvanaSession } from "./use-avana-session"
import {
  AvanaIdentityContext,
  AvanaSessionsContext,
  BorrowSessionContext,
  LendSessionContext,
  RewardsSessionContext,
  SwapSessionContext,
} from "./avana-sessions-context"

export type BorrowSession = ReturnType<typeof useBorrowSession>
export type LendSession = ReturnType<typeof useLendSession>
export type RewardsSession = ReturnType<typeof useRewardsSession>
export type SwapSession = ReturnType<typeof useSwapSession>

function usd6ToNumber(value: bigint) {
  return Number(value) / 1_000_000
}

function useRewardsEventBridge({
  walletId,
  borrow,
  lend,
  rewards,
}: {
  walletId: string
  borrow: BorrowSession
  lend: LendSession
  rewards: RewardsSession
}) {
  const seenIdsRef = useRef(new Set<string>())

  useEffect(() => {
    for (const item of borrow.transactionHistory) {
      const bridgeId = `borrow:${item.id}`
      // History is prepended newest-first, so the first already-bridged id means every older
      // item was bridged in a prior run — stop instead of scanning the whole array each change.
      if (seenIdsRef.current.has(bridgeId)) break
      if (item.status !== "success") continue
      seenIdsRef.current.add(bridgeId)

      if (item.kind === "borrow") {
        void rewards.recordActivityEvent({
          id: bridgeId,
          wallet: walletId,
          product: "borrow",
          type: "borrow_opened",
          amountUsd: usd6ToNumber(item.executedAmountUsd6),
          marketId: item.marketId,
          timestamp: item.timestamp,
        })
      }

      if (item.kind === "repay") {
        void rewards.recordActivityEvent({
          id: bridgeId,
          wallet: walletId,
          product: "borrow",
          type: "borrow_repaid",
          amountUsd: usd6ToNumber(item.executedAmountUsd6),
          marketId: item.marketId,
          timestamp: item.timestamp,
        })
      }
    }
  }, [borrow.transactionHistory, rewards, walletId])

  useEffect(() => {
    for (const item of lend.transactionHistory) {
      const bridgeId = `lend:${item.id}`
      if (seenIdsRef.current.has(bridgeId)) break // newest-first: older items already bridged
      if (item.status !== "success") continue
      seenIdsRef.current.add(bridgeId)

      if (item.kind === "claim") continue

      void rewards.recordActivityEvent({
        id: bridgeId,
        wallet: walletId,
        product: "lend",
        type: item.kind === "deposit" ? "lend_deposited" : "lend_withdrawn",
        marketId: item.marketId,
        amountUsd: item.amount,
        timestamp: item.timestamp,
      })
    }
  }, [lend.transactionHistory, rewards, walletId])
}

/**
 * Fold every NEW successful borrow-system action into the LOCAL in-session liquidity
 * ledger (the demo fallback used when the shared Convex ledger is unreachable). Existing/
 * persisted history is snapshotted as already-seen on mount so it isn't re-imported on
 * every page load.
 *
 * When the shared Convex ledger IS connected, this bridge stays out of the way: the
 * shared ledger is written server-side inside the idempotent recordTransaction (keyed by
 * intent), so folding here as well would double-count a single action (H20). The client
 * `recordDelta` is a no-op in connected mode, but we also skip early so the demo bridge
 * can never contribute to the shared cross-user numbers.
 */
function useLiquidityLedgerBridge({ borrow, enabled }: { borrow: BorrowSession; enabled: boolean }) {
  const { recordDelta, connected } = useMarketLiquidity()
  const seenIdsRef = useRef<Set<string> | null>(null)

  useEffect(() => {
    if (!enabled || connected) return
    if (seenIdsRef.current === null) {
      seenIdsRef.current = new Set(borrow.transactionHistory.map((item) => item.id))
      return
    }

    for (const item of borrow.transactionHistory) {
      if (item.status !== "success" || seenIdsRef.current.has(item.id)) continue
      seenIdsRef.current.add(item.id)

      const amountUsd = usd6ToNumber(item.executedAmountUsd6)
      if (!Number.isFinite(amountUsd) || amountUsd <= 0) continue

      if (item.kind === "borrow" && item.assetId) {
        recordDelta({ marketSlug: item.assetId, borrowedDeltaUsd: amountUsd })
      } else if (item.kind === "repay" && item.assetId) {
        recordDelta({ marketSlug: item.assetId, borrowedDeltaUsd: -amountUsd })
      } else if (item.kind === "deposit" && item.marketId) {
        recordDelta({ marketSlug: item.marketId, suppliedDeltaUsd: amountUsd })
      } else if (item.kind === "withdraw" && item.marketId) {
        recordDelta({ marketSlug: item.marketId, suppliedDeltaUsd: -amountUsd })
      }
    }
  }, [borrow.transactionHistory, enabled, connected, recordDelta])
}

export type AvanaSessions = {
  walletId: string
  walletAddress: string
  sandboxMode: true
  borrow: BorrowSession
  lend: LendSession
  rewards: RewardsSession
  swap: SwapSession
}

export type AvanaIdentity = Pick<AvanaSessions, "walletId" | "walletAddress" | "sandboxMode">

export function AvanaSessionsProvider({
  walletId,
  children,
  persistBorrowTransaction,
  persistLendTransaction,
  persistSwapTransaction,
  serverGetSwapQuote,
  remoteSwapTransactions,
  remoteRewardsState,
  remoteRewardsRevision,
  persistRewardsState,
  persistLocalState = true,
  sessionSource = "demo",
  authoritativeWalletPending = false,
}: {
  walletId?: string
  children: ReactNode
  persistBorrowTransaction?: (result: SandboxActionResult) => Promise<{
    id: string
    hash: string
    status: "success" | "failed" | "pending"
    simulated: boolean
    timestamp: number
  }>
  persistLendTransaction?: (result: LendSandboxActionResult) => Promise<LendTransactionResult>
  persistSwapTransaction?: (record: SwapTransactionRecord) => void | Promise<unknown>
  serverGetSwapQuote?: (request: SwapQuoteRequest) => Promise<SwapQuote>
  remoteSwapTransactions?: DurableSwapTransaction[]
  remoteRewardsState?: string | null
  remoteRewardsRevision?: number | null
  persistRewardsState?: (args: {
    stateJson: string
    expectedRevision?: number
  }) => Promise<{ revision?: number } | unknown>
  persistLocalState?: boolean
  sessionSource?: "demo" | "convex"
  /** Keep every wallet-backed surface loading until the authoritative Convex reads settle. */
  authoritativeWalletPending?: boolean
}) {
  const { deltas: liquidityDeltas } = useMarketLiquidity()
  const liquidityDeltasRef = useRef(liquidityDeltas)
  liquidityDeltasRef.current = liquidityDeltas
  const getLiquidityDeltas = useCallback(() => liquidityDeltasRef.current, [])

  const avana = useAvanaSession(walletId, sessionSource)
  const borrow = useBorrowSession({
    walletId: avana.walletId,
    sessionSeed: avana.borrowSessionSeed,
    persistState: persistLocalState,
    persistTransaction: persistBorrowTransaction,
    getLiquidityDeltas,
  })
  const lend = useLendSession({
    walletId: avana.walletId,
    sessionSeed: avana.lendSessionSeed,
    persistState: persistLocalState,
    persistTransaction: persistLendTransaction,
  })
  const rewards = useRewardsSession({
    walletId: avana.walletId,
    sessionSeed: avana.rewardsSessionSeed,
    persistState: persistLocalState,
    remoteState: remoteRewardsState,
    remoteRevision: remoteRewardsRevision,
    persistRemoteState: persistRewardsState,
  })
  const swap = useSwapSession({
    walletId: avana.walletId,
    persistState: persistLocalState,
    persistTransaction: persistSwapTransaction,
    serverGetQuote: serverGetSwapQuote,
    remoteTransactions: remoteSwapTransactions,
    seedDemoBalances: sessionSource === "demo",
  })

  const visibleBorrow = useMemo(
    () => (authoritativeWalletPending ? { ...borrow, isHydrated: false } : borrow),
    [authoritativeWalletPending, borrow],
  )
  const visibleLend = useMemo(
    () => (authoritativeWalletPending ? { ...lend, isHydrated: false } : lend),
    [authoritativeWalletPending, lend],
  )
  const visibleSwap = useMemo(
    () => (authoritativeWalletPending ? { ...swap, isHydrated: false } : swap),
    [authoritativeWalletPending, swap],
  )
  const visibleRewards = useMemo(
    () => (authoritativeWalletPending ? { ...rewards, hasHydratedStorage: false } : rewards),
    [authoritativeWalletPending, rewards],
  )

  useRewardsEventBridge({
    walletId: avana.walletId,
    borrow,
      lend,
    rewards,
  })

  useLiquidityLedgerBridge({ borrow, enabled: persistLocalState })

  const value = useMemo<AvanaSessions>(
    () => ({
      walletId: avana.walletId,
      walletAddress: avana.walletAddress,
      sandboxMode: avana.sandboxMode,
      borrow: visibleBorrow,
      lend: visibleLend,
      rewards: visibleRewards,
      swap: visibleSwap,
    }),
    [
      avana.walletId,
      avana.walletAddress,
      avana.sandboxMode,
      visibleBorrow,
      visibleLend,
      visibleRewards,
      visibleSwap,
    ],
  )
  const identity = useMemo<AvanaIdentity>(
    () => ({
      walletId: avana.walletId,
      walletAddress: avana.walletAddress,
      sandboxMode: avana.sandboxMode,
    }),
    [avana.walletId, avana.walletAddress, avana.sandboxMode],
  )

  return (
    <AvanaSessionsContext.Provider value={value}>
      <AvanaIdentityContext.Provider value={identity}>
        <BorrowSessionContext.Provider value={visibleBorrow}>
            <LendSessionContext.Provider value={visibleLend}>
              <RewardsSessionContext.Provider value={visibleRewards}>
                <SwapSessionContext.Provider value={visibleSwap}>
                  {children}
                </SwapSessionContext.Provider>
              </RewardsSessionContext.Provider>
            </LendSessionContext.Provider>
        </BorrowSessionContext.Provider>
      </AvanaIdentityContext.Provider>
    </AvanaSessionsContext.Provider>
  )
}

export {
  useAvanaIdentity,
  useAvanaSessions,
  useBorrowSessionContext,
  useBorrowSessionContextOptional,
  useLendSessionContext,
  useOptionalAvanaSessions,
  useRewardsSessionContext,
  useSwapSessionContext,
} from "./avana-sessions-context"
