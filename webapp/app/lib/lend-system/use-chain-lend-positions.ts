"use client"

import { useEffect, useMemo, useRef } from "react"
import { useAction, useQuery } from "convex/react"
import type { Address } from "viem"
import { api } from "@/convex/_generated/api"
import { chainPublicClient } from "@/app/lib/chain/public-client"
import { everyWhileVisible } from "@/app/lib/chain/visible-interval"
import { useLendSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import { useWalletActivity } from "@/app/lib/activity/use-wallet-activity"
import { readChainLendPositions, type LendHubAsset } from "@/app/lib/lend-system/chain-lend-positions"
import {
  lendPrincipal,
  readFullHistory,
  type HistoryRecordLike,
  type OlderHistoryLike,
} from "@/app/lib/lend-system/lend-principal"

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
 * {@link LEND_POSITIONS_REFRESH_MS} while the tab is visible, when it becomes visible again, when the markets change and
 * on {@link requestLendPositionsRefresh}. A guest reads nothing.
 *
 * The principal comes from the wallet's whole history (`wallet.history.older` on every chain). It is read when the
 * wallet, its markets or its latest Lend activity change, and is used only when every page was read and the history
 * holds the wallet's latest indexed Lend events (the export can lag the chain head); otherwise the principal stays the
 * current supply.
 */
export function useChainLendPositions(walletId: string) {
  const session = useLendSessionContext()
  const { hydratePositions } = session
  const wallet = isAddress(walletId) ? walletId : undefined
  const hubAssets = useQuery(api.hubAssets.list, wallet ? {} : "skip") as readonly LendHubAsset[] | undefined
  const older = useAction(api.wallet.history.older) as unknown as (args: {
    chainId: number
    wallet: string
    before?: string
  }) => Promise<OlderHistoryLike>
  const activity = useWalletActivity(walletId)
  const principal = useRef<{ wallet: string; value: Record<string, number> | null } | null>(null)

  // Stable keys, so the history is not read again on every Convex update.
  const marketsKey = useMemo(
    () => (hubAssets ?? []).map((a) => `${a.chainId}:${a.slug}:${a.lendReserves.length}`).join(","),
    [hubAssets],
  )
  const latestLendKeys = useMemo(
    () =>
      activity.rows
        .filter((r) => r.product === "lend")
        .map((r) => r.id)
        .join(","),
    [activity.rows],
  )

  useEffect(() => {
    if (!wallet || !hubAssets) return
    let cancelled = false
    const chains = [...new Set(hubAssets.map((a) => a.chainId))]
    void Promise.all(chains.map((chainId) => readFullHistory(older, chainId, wallet))).then((histories) => {
      if (cancelled) return
      let value: Record<string, number> | null = null
      if (histories.every((h): h is HistoryRecordLike[] => h !== null)) {
        const keys = new Set(histories.flat().map((r) => r.key))
        const complete = latestLendKeys === "" || latestLendKeys.split(",").every((key) => keys.has(key))
        if (complete) value = lendPrincipal(wallet, new Map(chains.map((c, i) => [c, histories[i]!])), hubAssets)
      }
      principal.current = { wallet, value }
    })
    return () => {
      cancelled = true
    }
    // hubAssets is read through marketsKey: its markets, not its live numbers, decide the principal.
  }, [wallet, marketsKey, latestLendKeys, older])

  // The latest Hub assets, read at each tick: a Convex update of their live numbers does not restart the timer or
  // trigger an extra chain read; a change of markets (marketsKey) does.
  const latestHubAssets = useRef(hubAssets)
  latestHubAssets.current = hubAssets
  const loaded = hubAssets !== undefined

  useEffect(() => {
    if (!wallet || !loaded) return
    let cancelled = false
    let inFlight = false
    const read = () => {
      const hubAssets = latestHubAssets.current
      if (inFlight || !hubAssets) return
      inFlight = true
      readChainLendPositions({ client: chainPublicClient, wallet, hubAssets })
        .then((next) => {
          const p = principal.current?.wallet === wallet ? principal.current.value : null
          if (!cancelled) hydratePositions({ ...next, principal: p })
        })
        .catch(() => {
          // Unreadable now; the next read tries again.
        })
        .finally(() => {
          inFlight = false
        })
    }
    read()
    // A hidden tab reads nothing; it catches up as soon as it is visible again.
    const stop = everyWhileVisible(read, LEND_POSITIONS_REFRESH_MS)
    refreshListeners.add(read)
    return () => {
      cancelled = true
      stop()
      refreshListeners.delete(read)
    }
  }, [wallet, loaded, marketsKey, hydratePositions])
}
