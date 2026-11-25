"use client"

/**
 * Starts the one-time read of a wallet's older on-chain history (Convex `wallet.backfill.run`) when the rewards say it has
 * not been read: Convex keeps 30 days of logs, so a wallet that began earlier gets its "Member since" and first-action
 * quests from this. Once per wallet per session, best effort; when it finishes, the rewards query updates by itself.
 */

import { useEffect, useRef } from "react"
import { useAction } from "convex/react"
import { isAddress } from "viem"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import type { WalletRewards } from "./use-wallet-rewards"

export function useHistoryBackfill(walletId: string | null | undefined, rewards: WalletRewards | undefined): void {
  // `hasConvexClient` is a build-time constant, so every render takes the same branch.
  if (!hasConvexClient) return
  useLiveHistoryBackfill(walletId, rewards)
}

function useLiveHistoryBackfill(walletId: string | null | undefined, rewards: WalletRewards | undefined): void {
  const run = useAction(api.wallet.backfill.run)
  const started = useRef<string | null>(null)
  const checked = rewards?.historyChecked
  useEffect(() => {
    const wallet = walletId && isAddress(walletId, { strict: false }) ? walletId.toLowerCase() : null
    if (!wallet || checked !== false || started.current === wallet) return
    started.current = wallet
    void run({ wallet }).catch(() => {})
  }, [walletId, checked, run])
}
