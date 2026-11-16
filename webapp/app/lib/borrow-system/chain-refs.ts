import type { ChainBorrowAccountRef, ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"

/** The wallet's chain references, as services/convex last named them (`wallet.positions.borrowAccounts`). */
export type ChainBorrowRefs = {
  wallet: string
  lenses: readonly { chainId: number; lens: string }[]
  accounts: readonly ChainBorrowAccountRef[]
  debtReserves: readonly ChainDebtReserveRef[]
}

let latest: ChainBorrowRefs | null = null
const refreshListeners = new Set<() => void>()

/** Set by the positions reader whenever services/convex answers. */
export function setChainBorrowRefs(refs: ChainBorrowRefs | null) {
  latest = refs
}

/** The references of `wallet`, or null before they load (or for another wallet). */
export function chainBorrowRefs(wallet: string): ChainBorrowRefs | null {
  return latest && latest.wallet.toLowerCase() === wallet.toLowerCase() ? latest : null
}

/** Asks the positions reader to re-read the chain now (after a transaction confirms). */
export function requestBorrowPositionsRefresh() {
  for (const listener of refreshListeners) listener()
}

export function onBorrowPositionsRefresh(listener: () => void) {
  refreshListeners.add(listener)
  return () => {
    refreshListeners.delete(listener)
  }
}
