"use client"

import { useEffect } from "react"
import { referralCodeFromSearch, storeReferralCode } from "@/app/lib/rewards/referrals"

/**
 * Keeps the invite code of a `?ref=<code>` link on the first visit, for the attribution after sign-in
 * (`ReferralAttributionSync`). Renders nothing.
 */
export function ReferralCapture() {
  useEffect(() => {
    const code = referralCodeFromSearch(window.location.search)
    if (code) storeReferralCode(code)
  }, [])
  return null
}
