"use client"

import { useMemo } from "react"
import { resolveWalletIdentity } from "@/app/lib/data/wallet/profiles"

type AvanaSession = {
  walletId: string
  walletAddress: string
}

/**
 * The wallet the product sessions are scoped to: the signed-in wallet address, or the guest id
 * when no wallet is connected.
 */
export function useAvanaSession(walletId?: string): AvanaSession {
  const profile = useMemo(() => resolveWalletIdentity(walletId), [walletId])
  return useMemo(() => ({ walletId: profile.id, walletAddress: profile.walletAddress }), [profile.id, profile.walletAddress])
}
