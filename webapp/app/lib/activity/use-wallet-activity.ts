"use client"

import { useMemo } from "react"
import { usePaginatedQuery } from "convex/react"
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
  hasMore: boolean
  loadMore: () => void
}

const NONE: WalletActivity = { rows: [], isLoading: false, hasMore: false, loadMore: () => {} }

const isAddress = (value: string): boolean => /^0x[0-9a-fA-F]{40}$/.test(value)

/**
 * The wallet's indexed activity on every served chain (services/convex `wallet.activity.listForWallet`: the last 30
 * days, newest first), paged, as feed rows. Older activity is served by `wallet.history.older` as raw logs without a
 * time or a USD value, so the feed stops at 30 days. Empty for a guest or without a Convex deployment.
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
  const markets = useBorrowSessionContextOptional()?.state.markets
  const rows = useMemo(
    () => mapWalletActivityRows(results as readonly WalletActivityRowLike[], markets),
    [results, markets],
  )
  return useMemo(
    () =>
      wallet
        ? {
            rows,
            isLoading: status === "LoadingFirstPage",
            hasMore: status === "CanLoadMore",
            loadMore: () => {
              if (status === "CanLoadMore") loadMore(WALLET_ACTIVITY_PAGE_SIZE)
            },
          }
        : NONE,
    [wallet, rows, status, loadMore],
  )
}
