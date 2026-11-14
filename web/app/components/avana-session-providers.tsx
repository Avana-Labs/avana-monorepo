"use client"

import { lazy, Suspense, type ReactNode } from "react"
import { ConvexProviderWithAuth, ConvexReactClient } from "convex/react"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { PendingConvexSessionProvider } from "@/app/lib/avana-session/pending-convex-session-provider"
import { hasConvexClient, MarketLiquidityProvider } from "@/app/lib/convex/market-liquidity-provider"
import { getSiweConvexClient, SiweConvexProvider } from "@/app/lib/convex/siwe-convex-provider"
import { useConvexSiweAuth, useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { useOpenGateAuthBootstrap } from "@/app/lib/siwe/use-open-gate-auth-bootstrap"
import { GUEST_WALLET_ID } from "@/app/lib/data/wallet/profiles"
import { isPlaywrightTestMode, shouldUseOpenGateSession, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"

const loadConvexSessionProvider = () => import("@/app/lib/avana-session/convex-session-provider")
const ConvexSessionProvider = lazy(async () => ({
  default: (await loadConvexSessionProvider()).ConvexSessionProvider,
}))

// Module-scope Convex client for the dev open-gate path. Mounted synchronously so the
// provider tree always has a Convex client before wallet queries fire.
//
// Reuse the shared SIWE client whenever a real NEXT_PUBLIC_CONVEX_URL is configured —
// including local open-gate/test-mode dev, which does have a backend. Only when the URL
// is genuinely absent (Playwright CI / Lighthouse without backend) do we fall back to an
// unreachable local port so useQuery resolves to undefined (loading) instead of throwing
// "Could not find Convex client". Pointing at the dead port when a real URL exists just
// spammed the console with failed ws://127.0.0.1:0 handshakes (unsuppressible browser logs).
const OFFLINE_CONVEX_URL = "http://127.0.0.1:0"
const openGateConvexClient = getSiweConvexClient() ?? new ConvexReactClient(OFFLINE_CONVEX_URL)

function OpenGateConvexProvider({ children }: { children: ReactNode }) {
  return (
    <ConvexProviderWithAuth client={openGateConvexClient} useAuth={useConvexSiweAuth}>
      {children}
    </ConvexProviderWithAuth>
  )
}

/** Instant Paint: always paint children; upgrade to Convex when JWT/chunk are ready. */
function LocalSessionFallback({ walletId, children }: { walletId: string; children: ReactNode }) {
  return <PendingConvexSessionProvider walletId={walletId}>{children}</PendingConvexSessionProvider>
}

function OpenGateSessionTree({ children }: { children: ReactNode }) {
  const { ready, error } = useOpenGateAuthBootstrap()
  const walletId = TEST_MODE_WALLET_ADDRESS

  if (error) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background px-6 text-center">
        <p className="text-sm text-muted-foreground">Open-gate Convex auth failed</p>
        <p className="max-w-md text-xs text-muted-foreground">{error}</p>
        <LocalSessionFallback walletId={walletId}>{children}</LocalSessionFallback>
      </div>
    )
  }

  // Paint product chrome immediately with the local session while the JWT mints /
  // Convex session chunk loads. Soft-upgrade to ConvexSessionProvider when ready —
  // never return null (blank Instant Paint regression).
  if (!ready || !hasConvexClient) {
    return <LocalSessionFallback walletId={walletId}>{children}</LocalSessionFallback>
  }

  return (
    <Suspense fallback={<LocalSessionFallback walletId={walletId}>{children}</LocalSessionFallback>}>
      <ConvexSessionProvider walletId={walletId}>{children}</ConvexSessionProvider>
    </Suspense>
  )
}

export function AvanaSessionProviders({ walletId, children }: { walletId?: string; children: ReactNode }) {
  const { authedWallet, isSignedIn } = useSiweAuth()
  if (isPlaywrightTestMode()) {
    return (
      <OpenGateConvexProvider>
        <MarketLiquidityProvider live={false}>
          <AvanaSessionsProvider walletId={TEST_MODE_WALLET_ADDRESS} persistLocalState persistUmbrellaState={false}>
            {children}
          </AvanaSessionsProvider>
        </MarketLiquidityProvider>
      </OpenGateConvexProvider>
    )
  }
  if (shouldUseOpenGateSession()) {
    return (
      <OpenGateConvexProvider>
        <MarketLiquidityProvider live={Boolean(hasConvexClient)}>
          <OpenGateSessionTree>{children}</OpenGateSessionTree>
        </MarketLiquidityProvider>
      </OpenGateConvexProvider>
    )
  }
  // A signed-in SIWE wallet drives the entire session (positions, seeds, Convex reads). A guest
  // gets an empty, non-persisted wallet: live market data from the public Convex reads, no demo
  // portfolio. An explicit `walletId` keeps its local session for callers that pass one.
  const liveSession = Boolean(hasConvexClient && isSignedIn && authedWallet)
  // SiweConvexProvider here (this module is only loaded for product routes) so the shared
  // client's Connect + Authenticate fire while this SSR'd tree hydrates — not after a later
  // lazy gate import. Nested wrappers reuse the same client (no second socket).
  return (
    <SiweConvexProvider>
      <MarketLiquidityProvider live={hasConvexClient}>
        {liveSession && authedWallet ? (
          <Suspense fallback={<LocalSessionFallback walletId={authedWallet}>{children}</LocalSessionFallback>}>
            <ConvexSessionProvider walletId={authedWallet}>{children}</ConvexSessionProvider>
          </Suspense>
        ) : walletId ? (
          <AvanaSessionsProvider walletId={walletId}>{children}</AvanaSessionsProvider>
        ) : (
          <AvanaSessionsProvider
            walletId={GUEST_WALLET_ID}
            sessionSource="convex"
            persistLocalState={false}
            persistUmbrellaState={false}
          >
            {children}
          </AvanaSessionsProvider>
        )}
      </MarketLiquidityProvider>
    </SiweConvexProvider>
  )
}
