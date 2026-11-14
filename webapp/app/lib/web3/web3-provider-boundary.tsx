"use client"

import dynamic from "next/dynamic"
import type { ReactNode } from "react"
import { loadWeb3Module, useWalletGate } from "@/app/lib/web3/wallet-gate"

/**
 * Hosts the wallet SDK (wagmi + viem + connectkit + walletconnect + coinbase — ~1MB+ of JS) as a
 * SIBLING of the app, mounted only once the gate is active. `ssr: false` keeps it out of the
 * server bundle and off the client critical path.
 *
 * It is deliberately NOT an ancestor of `children`: wrapping the app and switching the wrapper
 * on later remounted the entire tree (header, auth gate, Convex provider, page) seconds after
 * first paint. The components that need wagmi context register slots (see `wallet-slots.ts`)
 * and the runtime renders into them via portals; action pages read wrong-network state from a
 * store the runtime publishes to. The app subtree never changes parent.
 *
 * `loadWeb3Module` is the same import the gate uses to preload, so there is one chunk group.
 */
const LazyWeb3Runtime = dynamic(() => loadWeb3Module().then((m) => m.Web3Runtime), { ssr: false })

export function Web3ProviderBoundary({ children }: { children: ReactNode }) {
  const { active } = useWalletGate()
  return (
    <>
      {children}
      {active ? <LazyWeb3Runtime /> : null}
    </>
  )
}
