"use client"

/**
 * What the referral dialog shows while it is open: the signed-in wallet's invite link (its code is created on first use)
 * and how many friends it invited and how many of them are active (Convex `wallet.referrals.summary`). Without a sign-in
 * or a deployment there is no link and the counts are zero.
 */

import { useEffect, useState } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { useSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import { fetchMyReferralCode, referralLink } from "./referrals"

export type ReferralDialogData = { link: string | null; invited: number; active: number }

const NONE: ReferralDialogData = { link: null, invited: 0, active: 0 }

export function useReferralDialogData(open: boolean): ReferralDialogData {
  // `hasConvexClient` is a build-time constant, so every render takes the same branch.
  if (!hasConvexClient) return NONE
  return useLiveReferralDialogData(open)
}

function useLiveReferralDialogData(open: boolean): ReferralDialogData {
  const session = useSiweToken()
  const wallet = session?.wallet ?? null
  const [code, setCode] = useState<string | null>(null)
  const summary = useQuery(api.wallet.referrals.summary, open && wallet ? { wallet } : "skip")

  useEffect(() => {
    if (!open || !wallet) return
    let live = true
    void fetchMyReferralCode().then((c) => {
      if (live && c) setCode(c)
    })
    return () => {
      live = false
    }
  }, [open, wallet])

  const shown = wallet ? (summary?.code ?? code) : null
  return {
    link: shown && typeof window !== "undefined" ? referralLink(window.location.origin, shown) : null,
    invited: summary?.invited ?? 0,
    active: summary?.active ?? 0,
  }
}
