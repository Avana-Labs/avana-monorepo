import type { ChainBorrowAccountRef, ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"

/** A listed market with its CDP Spoke and the Borrow list's pool slug. */
export type ChainMarketRef = { chainId: number; marketId: string; spoke: string; poolSlug: string }

/** The wallet's chain references, as services/convex last named them (`wallet.positions.borrowAccounts`). */
export type ChainBorrowRefs = {
  wallet: string
  lenses: readonly { chainId: number; lens: string }[]
  accounts: readonly ChainBorrowAccountRef[]
  /** Every listed market; empty from an older services/convex. */
  markets?: readonly ChainMarketRef[]
  debtReserves: readonly ChainDebtReserveRef[]
}

/** One LP NFT in the wallet that an Avana market accepts, as the wallet balances reader found it. */
export type PledgeableLp = {
  chainId: number
  marketId: string
  integrationId: number
  /** bytes32 position key (Slipstream: the generation in the top byte). */
  positionKey: `0x${string}`
  npm: string
  tokenId: bigint
  lpVault: string
  valueUsd6: bigint
}

let latest: ChainBorrowRefs | null = null
let latestLps: { wallet: string; lps: readonly PledgeableLp[] } | null = null
const refreshListeners = new Set<() => void>()

/** Set by the positions reader whenever services/convex answers. */
export function setChainBorrowRefs(refs: ChainBorrowRefs | null) {
  latest = refs
}

/** The references of `wallet`, or null before they load (or for another wallet). */
export function chainBorrowRefs(wallet: string): ChainBorrowRefs | null {
  return latest && latest.wallet.toLowerCase() === wallet.toLowerCase() ? latest : null
}

/** Set by the wallet balances reader with the wallet's LP NFTs that a market accepts. */
export function setPledgeableLps(wallet: string, lps: readonly PledgeableLp[] | null) {
  latestLps = lps ? { wallet, lps } : null
}

/** The LP NFTs of `wallet` that a market accepts; empty before they load (or for another wallet). */
export function pledgeableLps(wallet: string): readonly PledgeableLp[] {
  return latestLps && latestLps.wallet.toLowerCase() === wallet.toLowerCase() ? latestLps.lps : []
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
