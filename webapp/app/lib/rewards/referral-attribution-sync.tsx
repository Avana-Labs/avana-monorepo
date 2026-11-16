"use client"

import { useEffect } from "react"
import { useSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import { attributeReferral, clearStoredReferralCode, getStoredReferralCode } from "./referrals"

/**
 * When a visitor who arrived with a referral code is signed in, asks Convex to attribute the wallet to the code's owner,
 * then forgets the code (whatever Convex answered: it is not retried). A failed call keeps the code for the next load.
 */
export function ReferralAttributionSync() {
  const session = useSiweToken()
  const wallet = session?.wallet ?? null
  useEffect(() => {
    if (!wallet) return
    const code = getStoredReferralCode()
    if (!code) return
    void attributeReferral(code).then((result) => {
      if (result !== null) clearStoredReferralCode()
    })
  }, [wallet])
  return null
}
