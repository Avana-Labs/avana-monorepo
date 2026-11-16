"use client"

import { useEffect, useSyncExternalStore } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { SWAP_CHAIN_ID } from "./catalog"
import type { SwapContracts } from "./onchain-config"
import { swapProviderId } from "./providers"

let current: SwapContracts | null = null
const listeners = new Set<() => void>()

export function swapContracts(): SwapContracts | null {
  return current
}

export function setSwapContracts(next: SwapContracts | null) {
  current = next
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function SwapContractsQuery() {
  const contracts = useQuery(api.deployments.swapContractsOf, { chainId: SWAP_CHAIN_ID })
  useEffect(() => {
    if (contracts !== undefined) setSwapContracts(contracts as SwapContracts | null)
  }, [contracts])
  return null
}

/**
 * Loads the swap chain's venues and tokens from Convex (`deployments.swapContractsOf`) when this
 * network quotes on its own pools (NEXT_PUBLIC_AVANA_SWAP_PROVIDER=onchain-pools).
 */
export function SwapContractsSync() {
  return hasConvexClient && swapProviderId() === "onchain-pools" ? <SwapContractsQuery /> : null
}

/** The swap chain's contracts; null until loaded or on a network that does not quote on its own pools. */
export function useSwapContracts(): SwapContracts | null {
  return useSyncExternalStore(subscribe, swapContracts, () => null)
}
