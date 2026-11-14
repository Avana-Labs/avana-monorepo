"use client"

import type { ReactNode } from "react"
import { usePathname } from "next/navigation"
import { ConvexProviderWithAuth, ConvexReactClient } from "convex/react"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { ConvexMarketSnapshotHydrators } from "@/app/lib/avana-session/convex-market-snapshot-hydrators"
import { resolveProductRuntimeScope } from "@/app/lib/avana-session/product-runtime-scope"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { getSiweConvexClient, SiweConvexProvider } from "@/app/lib/convex/siwe-convex-provider"
import { useConvexSiweAuth, useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { useOpenGateAuthBootstrap } from "@/app/lib/siwe/use-open-gate-auth-bootstrap"
import { GUEST_WALLET_ID } from "@/app/lib/data/wallet/profiles"
import { isPlaywrightTestMode, shouldUseOpenGateSession, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"

// Dev open-gate / Playwright: a Convex client is always mounted so queries resolve to "loading"
// instead of throwing when no deployment URL is configured (CI, Lighthouse).
const OFFLINE_CONVEX_URL = "http://127.0.0.1:0"
const openGateConvexClient = getSiweConvexClient() ?? new ConvexReactClient(OFFLINE_CONVEX_URL)

function OpenGateConvexProvider({ children }: { children: ReactNode }) {
  useOpenGateAuthBootstrap()
  return (
    <ConvexProviderWithAuth client={openGateConvexClient} useAuth={useConvexSiweAuth}>
      {children}
    </ConvexProviderWithAuth>
  )
}

function SessionTree({ walletId, live, children }: { walletId: string; live: boolean; children: ReactNode }) {
  const pathname = usePathname()
  const scope = resolveProductRuntimeScope(pathname)
  return (
    <AvanaSessionsProvider walletId={walletId}>
      {live ? <ConvexMarketSnapshotHydrators scope={scope} /> : null}
      {children}
    </AvanaSessionsProvider>
  )
}

/**
 * Product-route session tree: Borrow, Lend and Swap state for the connected wallet (the guest id
 * when none), with markets from services/convex. No page waits for a sign-in.
 */
export function AvanaSessionProviders({ walletId, children }: { walletId?: string; children: ReactNode }) {
  const { authedWallet, isSignedIn } = useSiweAuth()
  if (isPlaywrightTestMode() || shouldUseOpenGateSession()) {
    return (
      <OpenGateConvexProvider>
        <SessionTree walletId={TEST_MODE_WALLET_ADDRESS} live={hasConvexClient}>
          {children}
        </SessionTree>
      </OpenGateConvexProvider>
    )
  }
  const sessionWallet = walletId ?? (isSignedIn && authedWallet ? authedWallet : GUEST_WALLET_ID)
  return (
    <SiweConvexProvider>
      <SessionTree walletId={sessionWallet} live={hasConvexClient}>
        {children}
      </SessionTree>
    </SiweConvexProvider>
  )
}
