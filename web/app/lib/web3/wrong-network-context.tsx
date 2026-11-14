"use client"

import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react"
import { TARGET_CHAIN_ID, TARGET_CHAIN_NAME } from "@/app/lib/web3/target-chain"

/**
 * Wrong-network state, published by the (lazily-mounted) wallet provider and read by the
 * wrong-network banner and the action-page submit guard.
 *
 * This module is deliberately wagmi-free: the guard is reached statically from the Express
 * home page (which embeds the borrow client), so importing wagmi here would drag the wallet
 * SDK back onto the guest critical path. Instead the wagmi hook runs INSIDE the mounted
 * `Web3Provider`, which feeds this context; consumers outside a mounted provider read the
 * inert default (a guest with no wallet can't be on the wrong network).
 */
export type WrongNetworkState = {
  /** True only when a wallet is connected AND on a chain other than the target. */
  isWrongNetwork: boolean
  /** The chain the app requires (e.g. "Ethereum"). */
  targetChainName: string
  targetChainId: number
  /** A switch request is in flight (wallet prompt open). */
  isSwitching: boolean
  /** Human-readable reason the last switch attempt failed, or null. */
  switchError: string | null
  /** Ask the wallet to switch to the target chain; resolves true on success. */
  switchToTargetChain: () => Promise<boolean>
}

const INERT: WrongNetworkState = {
  isWrongNetwork: false,
  targetChainName: TARGET_CHAIN_NAME,
  targetChainId: TARGET_CHAIN_ID,
  isSwitching: false,
  switchError: null,
  switchToTargetChain: async () => false,
}

const WrongNetworkContext = createContext<WrongNetworkState | null>(null)

export function WrongNetworkStateProvider({ value, children }: { value: WrongNetworkState; children: ReactNode }) {
  return <WrongNetworkContext.Provider value={value}>{children}</WrongNetworkContext.Provider>
}

// The wallet SDK is mounted as a SIBLING of the app (so mounting it never remounts the app), which
// means it cannot be an ancestor of the action pages. It publishes its state here instead.
let published: WrongNetworkState | null = null
const listeners = new Set<() => void>()
const subscribe = (listener: () => void) => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
const getSnapshot = () => published
const getServerSnapshot = () => null

/** Called by the mounted wallet provider whenever wagmi-backed wrong-network state changes. */
export function publishWrongNetworkState(state: WrongNetworkState | null) {
  published = state
  for (const listener of listeners) listener()
}

/** Read wrong-network state. Returns the inert default when no wallet provider is mounted. */
export function useWrongNetworkState(): WrongNetworkState {
  const fromContext = useContext(WrongNetworkContext)
  const fromStore = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot)
  return fromContext ?? fromStore ?? INERT
}
