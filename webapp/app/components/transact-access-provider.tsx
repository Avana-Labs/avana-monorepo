"use client"

import { useEffect, type ReactNode } from "react"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { IS_DEV_SHORTCUT_MODE } from "@/app/lib/test-mode"
import { TransactAccessContext } from "@/app/lib/transact-access"
import { clearGetStartedIntent, hasGetStartedIntent } from "@/app/lib/web3/get-started-intent"
import { trackEvent } from "@/app/lib/analytics/track-event"

/**
 * Every route renders for everyone: no page waits for a sign-in. This only tells the action CTAs
 * whether the viewer still has to connect ("guest") or may continue ("ready").
 */
export function TransactAccessProvider({ children }: { children: ReactNode }) {
  const { authedWallet, isSignedIn } = useSiweAuth()
  const ready = IS_DEV_SHORTCUT_MODE || (isSignedIn && Boolean(authedWallet))

  useEffect(() => {
    if (!ready || !hasGetStartedIntent()) return
    clearGetStartedIntent()
    trackEvent("get_started_signed_in")
  }, [ready])

  return <TransactAccessContext.Provider value={ready ? "ready" : "guest"}>{children}</TransactAccessContext.Provider>
}
