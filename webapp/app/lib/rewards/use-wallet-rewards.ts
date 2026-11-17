"use client"

/**
 * A wallet's reward points, from Convex `wallet.rewards.summary`: tenure, quest and fee points, and the completed
 * quests. Zero for a guest id, a null wallet or without a Convex deployment; undefined while loading.
 */

import { useMemo } from "react"
import { useQuery } from "convex/react"
import { isAddress } from "viem"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { DEFAULT_REDEMPTION } from "@/convex/lib/redemption"
import type { RedemptionRules } from "./redeem-points"

export type WalletRewards = {
  /** Points earned in total: tenure, quests and fees. */
  earnedPoints: number
  completedQuests: ReadonlySet<string>
  /** Whether the wallet's older history was read, so its first activity and quests are complete. */
  historyChecked: boolean
  /** Points left to redeem (earned less spent), the redemption rules, and the discounts held now. */
  availablePoints: number
  redemption: RedemptionRules
  activeRedemptions: readonly { bps: number; endsAt: number }[]
}

const NO_REWARDS: WalletRewards = {
  earnedPoints: 0,
  completedQuests: new Set(),
  historyChecked: true,
  availablePoints: 0,
  redemption: DEFAULT_REDEMPTION,
  activeRedemptions: [],
}

export function useWalletRewards(walletId: string | null | undefined): WalletRewards | undefined {
  // `hasConvexClient` is a build-time constant, so every render takes the same branch.
  if (!hasConvexClient) return NO_REWARDS
  return useLiveWalletRewards(walletId)
}

function useLiveWalletRewards(walletId: string | null | undefined): WalletRewards | undefined {
  const wallet = walletId && isAddress(walletId, { strict: false }) ? walletId : null
  const summary = useQuery(api.wallet.rewards.summary, wallet ? { wallet } : "skip")
  return useMemo(
    () =>
      wallet === null
        ? NO_REWARDS
        : summary === undefined
          ? undefined
          : {
              earnedPoints: summary.earnedPoints,
              completedQuests: new Set(summary.completedQuests),
              historyChecked: summary.historyChecked,
              availablePoints: summary.availablePoints,
              redemption: summary.redemption,
              activeRedemptions: summary.activeRedemptions,
            },
    [wallet, summary],
  )
}
