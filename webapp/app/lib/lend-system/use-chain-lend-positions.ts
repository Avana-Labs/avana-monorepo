"use client"

import { useEffect } from "react"
import { useQuery } from "convex/react"
import type { Address } from "viem"
import { api } from "@/convex/_generated/api"
import { chainPublicClient } from "@/app/lib/chain/public-client"
import { useLendSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import { readChainLendPositions, type LendHubAsset } from "@/app/lib/lend-system/chain-lend-positions"

/** How often the wallet's supplies are re-read at the chain head. */
export const LEND_POSITIONS_REFRESH_MS = 15_000

const isAddress = (value: string): value is Address => /^0x[0-9a-fA-F]{40}$/.test(value)

const refreshListeners = new Set<() => void>()

/** Asks the lend positions reader to re-read the chain now (after a lend transaction confirms). */
export function requestLendPositionsRefresh() {
  for (const listener of refreshListeners) listener()
}

/**
 * Keeps the lend session's positions in step with the chain on both app chains: services/convex names the Hub assets
 * and their lend reserves (`hubAssets.list`), the Lend Spokes give the wallet's supplies. Re-read every
 * {@link LEND_POSITIONS_REFRESH_MS} and on {@link requestLendPositionsRefresh}. A guest reads nothing.
 */
export function useChainLendPositions(walletId: string) {
  const session = useLendSessionContext()
  const { hydratePositions } = session
  const wallet = isAddress(walletId) ? walletId : undefined
  const hubAssets = useQuery(api.hubAssets.list, wallet ? {} : "skip") as readonly LendHubAsset[] | undefined

  useEffect(() => {
    if (!wallet || !hubAssets) return
    let cancelled = false
    let inFlight = false
    const read = () => {
      if (inFlight) return
      inFlight = true
      readChainLendPositions({ client: chainPublicClient, wallet, hubAssets })
        .then((next) => {
          if (!cancelled) hydratePositions(next)
        })
        .catch(() => {
          // Unreadable now; the next read tries again.
        })
        .finally(() => {
          inFlight = false
        })
    }
    read()
    const timer = setInterval(read, LEND_POSITIONS_REFRESH_MS)
    refreshListeners.add(read)
    return () => {
      cancelled = true
      clearInterval(timer)
      refreshListeners.delete(read)
    }
  }, [wallet, hubAssets, hydratePositions])
}
