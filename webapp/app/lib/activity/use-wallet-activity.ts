"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { useAction, usePaginatedQuery, useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { useBorrowSessionContextOptional } from "@/app/lib/avana-session/avana-sessions-context"
import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio/types"
import { mapWalletActivityRows, type WalletActivityRowLike } from "./wallet-activity"

/** Rows read per page of the wallet's indexed activity. */
export const WALLET_ACTIVITY_PAGE_SIZE = 20

export type WalletActivity = {
  rows: PortfolioActivityRow[]
  isLoading: boolean
  /** True while an older page (`wallet.history.older`) is read. */
  isLoadingMore: boolean
  hasMore: boolean
  loadMore: () => void
}

const NONE: WalletActivity = { rows: [], isLoading: false, isLoadingMore: false, hasMore: false, loadMore: () => {} }

const isAddress = (value: string): boolean => /^0x[0-9a-fA-F]{40}$/.test(value)

/** The fields of `wallet.history.older`'s answer read here (services/convex `OlderHistory`). */
type OlderPage =
  | { status: "ok"; next: string | null; rows?: readonly WalletActivityRowLike[] }
  | { status: "unavailable" | "rateLimited" }

type OlderAction = (args: { chainId: number; wallet: string; before?: string; rows: true }) => Promise<OlderPage>

/** Where each chain's older history stands: the next page's `before`, or done. */
type OlderCursor = { before?: string; done: boolean }

type OlderState = { wallet: string | null; cursors: Record<number, OlderCursor>; rows: WalletActivityRowLike[] }

const EMPTY_OLDER: OlderState = { wallet: null, cursors: {}, rows: [] }

/**
 * The wallet's indexed activity on every served chain, newest first, as feed rows: the last 30 days
 * (services/convex `wallet.activity.listForWallet`), paged, then, once those are all read, one page of older activity
 * per chain (`wallet.history.older`) each time `loadMore` is called. Older rows carry a token amount and no USD value.
 * A chain whose history is rate limited or unavailable is asked again on the next `loadMore`. Empty for a guest or
 * without a Convex deployment.
 */
export function useWalletActivity(walletId: string | null | undefined): WalletActivity {
  // `hasConvexClient` is a build-time constant, so every render takes the same branch.
  if (!hasConvexClient) return NONE
  return useLiveWalletActivity(walletId)
}

function useLiveWalletActivity(walletId: string | null | undefined): WalletActivity {
  const wallet = walletId && isAddress(walletId) ? walletId.toLowerCase() : null
  const { results, status, loadMore } = usePaginatedQuery(
    api.wallet.activity.listForWallet,
    wallet ? { wallet } : "skip",
    { initialNumItems: WALLET_ACTIVITY_PAGE_SIZE },
  )
  const chains = useQuery(api.deployments.explorers, wallet ? {} : "skip") as readonly { chainId: number }[] | undefined
  const older = useAction(api.wallet.history.older) as unknown as OlderAction
  const markets = useBorrowSessionContextOptional()?.state.markets

  const [olderState, setOlderState] = useState<OlderState>(EMPTY_OLDER)
  const [olderLoading, setOlderLoading] = useState(false)
  const inFlight = useRef(false)
  const currentWallet = useRef(wallet)
  useEffect(() => {
    currentWallet.current = wallet
  }, [wallet])
  // Another wallet starts from no older rows.
  const olderOfWallet = olderState.wallet === wallet ? olderState : EMPTY_OLDER

  const olderPending = useMemo(
    () => (chains ?? []).map((c) => c.chainId).filter((chainId) => !olderOfWallet.cursors[chainId]?.done),
    [chains, olderOfWallet.cursors],
  )

  const loadOlder = useCallback(async () => {
    if (!wallet || olderPending.length === 0 || inFlight.current) return
    inFlight.current = true
    setOlderLoading(true)
    const pages = await Promise.all(
      olderPending.map(async (chainId) => {
        try {
          return await older({ chainId, wallet, before: olderOfWallet.cursors[chainId]?.before, rows: true })
        } catch {
          return null
        }
      }),
    )
    inFlight.current = false
    setOlderLoading(false)
    if (currentWallet.current !== wallet) return
    setOlderState((prev) => {
      const base = prev.wallet === wallet ? prev : { ...EMPTY_OLDER, wallet }
      const cursors = { ...base.cursors }
      const rows = [...base.rows]
      pages.forEach((page, i) => {
        if (page?.status !== "ok") return
        cursors[olderPending[i]!] = page.next === null ? { done: true } : { before: page.next, done: false }
        rows.push(...(page.rows ?? []))
      })
      return { wallet, cursors, rows }
    })
  }, [wallet, olderPending, olderOfWallet.cursors, older])

  const rows = useMemo(() => {
    const recent = results as readonly WalletActivityRowLike[]
    const seen = new Set(recent.map((r) => r.id))
    // An event in both (the history reaches into the last 30 days) is shown once.
    const olderRows = olderOfWallet.rows.filter((r) => {
      if (seen.has(r.id)) return false
      seen.add(r.id)
      return true
    })
    return mapWalletActivityRows([...recent, ...olderRows], markets)
  }, [results, olderOfWallet.rows, markets])

  const exhausted = status === "Exhausted"
  return useMemo(
    () =>
      wallet
        ? {
            rows,
            isLoading: status === "LoadingFirstPage",
            isLoadingMore: olderLoading,
            hasMore: status === "CanLoadMore" || (exhausted && chains !== undefined && olderPending.length > 0),
            loadMore: () => {
              if (status === "CanLoadMore") loadMore(WALLET_ACTIVITY_PAGE_SIZE)
              else if (exhausted) void loadOlder()
            },
          }
        : NONE,
    [wallet, rows, status, exhausted, chains, olderPending.length, olderLoading, loadMore, loadOlder],
  )
}
