"use client"

import { useMemo, type ReactNode } from "react"
import { useBorrowSession } from "@/app/lib/borrow-system/use-borrow-session"
import { useLendSession } from "@/app/lib/lend-system/use-lend-session"
import { useSwapSession } from "@/app/lib/swap-system/use-swap-session"
import { useAvanaSession } from "./use-avana-session"
import {
  AvanaIdentityContext,
  AvanaSessionsContext,
  BorrowSessionContext,
  LendSessionContext,
  SwapSessionContext,
} from "./avana-sessions-context"

export type BorrowSession = ReturnType<typeof useBorrowSession>
export type LendSession = ReturnType<typeof useLendSession>
export type SwapSession = ReturnType<typeof useSwapSession>

export type AvanaSessions = {
  walletId: string
  walletAddress: string
  borrow: BorrowSession
  lend: LendSession
  swap: SwapSession
}

export type AvanaIdentity = Pick<AvanaSessions, "walletId" | "walletAddress">

/**
 * Mounts the per-wallet Borrow, Lend and Swap state. Markets are filled from services/convex by
 * `ConvexMarketSnapshotHydrators`; wallet positions and balances stay empty until the chain reads
 * are wired.
 */
export function AvanaSessionsProvider({ walletId, children }: { walletId?: string; children: ReactNode }) {
  const avana = useAvanaSession(walletId)
  const borrow = useBorrowSession({ walletId: avana.walletId })
  const lend = useLendSession({ walletId: avana.walletId })
  const swap = useSwapSession({ walletId: avana.walletId })

  const value = useMemo<AvanaSessions>(
    () => ({ walletId: avana.walletId, walletAddress: avana.walletAddress, borrow, lend, swap }),
    [avana.walletId, avana.walletAddress, borrow, lend, swap],
  )
  const identity = useMemo<AvanaIdentity>(
    () => ({ walletId: avana.walletId, walletAddress: avana.walletAddress }),
    [avana.walletId, avana.walletAddress],
  )

  return (
    <AvanaSessionsContext.Provider value={value}>
      <AvanaIdentityContext.Provider value={identity}>
        <BorrowSessionContext.Provider value={borrow}>
          <LendSessionContext.Provider value={lend}>
            <SwapSessionContext.Provider value={swap}>{children}</SwapSessionContext.Provider>
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
  useSwapSessionContext,
} from "./avana-sessions-context"
