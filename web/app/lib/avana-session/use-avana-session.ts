"use client"

import { useMemo } from "react"
import { buildBorrowSessionSeed, buildConvexBorrowSessionSeed } from "@/app/lib/borrow-system/demo-session"
import { resolveWalletIdentity } from "@/app/lib/data/wallet/profiles"
import { buildConvexLendSessionSeed, buildLendSessionSeed } from "@/app/lib/lend-system/demo-session"
import { buildConvexMultiplySessionSeed, buildMultiplySessionSeed } from "@/app/lib/multiply-system/demo-session"
import { buildRewardsSessionSeed } from "@/app/lib/rewards-system"

type AvanaSession = {
  walletId: string
  walletAddress: string
  sandboxMode: true
  borrowSessionSeed: string
  multiplySessionSeed: string
  lendSessionSeed: string
  rewardsSessionSeed: string
}

/**
 * Build the per-wallet sandbox session. `walletId` defaults to the built-in demo profile id;
 * after SIWE sign-in the providers pass the authed wallet ADDRESS, scoping every product hook,
 * seed, and Convex read to the signed wallet.
 */
export function useAvanaSession(walletId?: string, source: "demo" | "convex" = "demo"): AvanaSession {
  const profile = useMemo(() => resolveWalletIdentity(walletId), [walletId])

  return useMemo(
    () => ({
      walletId: profile.id,
      walletAddress: profile.walletAddress,
      sandboxMode: true as const,
      borrowSessionSeed:
        source === "convex" ? buildConvexBorrowSessionSeed(profile.id) : buildBorrowSessionSeed(profile.id),
      multiplySessionSeed:
        source === "convex" ? buildConvexMultiplySessionSeed(profile.id) : buildMultiplySessionSeed(profile.id),
      lendSessionSeed: source === "convex" ? buildConvexLendSessionSeed(profile.id) : buildLendSessionSeed(profile.id),
      rewardsSessionSeed: buildRewardsSessionSeed(),
    }),
    [profile.id, profile.walletAddress, source],
  )
}
