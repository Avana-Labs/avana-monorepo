"use client"

import { lazy, Suspense } from "react"
import { hasConvexClient } from "@/app/lib/convex/market-liquidity-provider"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { IS_DEV_SHORTCUT_MODE } from "@/app/lib/test-mode"

const ConnectedPreferencesProfileSync = lazy(async () => ({
  default: (await import("./preferences-profile-sync-connected")).PreferencesProfileSyncConnected,
}))

export function PreferencesProfileSync() {
  const { authedWallet, isSignedIn } = useSiweAuth()
  if (!hasConvexClient || IS_DEV_SHORTCUT_MODE || !isSignedIn || !authedWallet) return null
  return (
    <Suspense fallback={null}>
      <ConnectedPreferencesProfileSync wallet={authedWallet} />
    </Suspense>
  )
}
