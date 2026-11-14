"use client"

import { createContext, useCallback, useContext, useSyncExternalStore, type ReactNode } from "react"
import { fetchSiweAccessToken, getSiweSession, hydrateSiweSession, subscribeSiwe, type SiweSession } from "./auth-store"
import { IS_DEV_SHORTCUT_MODE, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"

/**
 * The session the SERVER verified from the `avana_siwe` cookie, used as the store's hydration
 * snapshot so signed-in users never hydrate through a signed-out frame. MUST be context, not
 * module state — the server renders many requests in one process.
 */
const ServerSiweSessionContext = createContext<SiweSession | null>(null)

export function SiweServerSessionProvider({ session, children }: { session: SiweSession | null; children: ReactNode }) {
  if (typeof window !== "undefined") hydrateSiweSession(session)
  return <ServerSiweSessionContext.Provider value={session}>{children}</ServerSiweSessionContext.Provider>
}

/** Reactively read non-secret SIWE session metadata (null when signed out). */
export function useSiweToken(): SiweSession | null {
  const serverSession = useContext(ServerSiweSessionContext)
  return useSyncExternalStore(subscribeSiwe, getSiweSession, () => serverSession)
}

const noopSubscribe = () => () => {}

/**
 * `false` on the server and the FIRST client render, then `true`. Gates hold a neutral
 * placeholder in that window instead of flashing onboarding at a signed-in user, since the
 * session store's server snapshot is `null`. Unlike a `useState`+`useEffect` mounted flag this
 * returns `true` immediately on any later remount, so a remounting parent can't reflash.
 */
export function useHydrated(): boolean {
  return useSyncExternalStore(
    noopSubscribe,
    () => true,
    () => false,
  )
}

/**
 * Compatibility name retained for callers that only need the authenticated wallet.
 * Access tokens are now private, memory-only implementation details.
 */
export function useLiveSiweToken(): SiweSession | null {
  return useSiweToken()
}

/**
 * The `useAuth` hook for `ConvexProviderWithAuth`. Convex calls `fetchAccessToken`
 * to attach the JWT to authed function calls; public queries still work when null.
 */
export function useConvexSiweAuth() {
  const session = useLiveSiweToken()
  const fetchAccessToken = useCallback(
    async ({ forceRefreshToken }: { forceRefreshToken: boolean }) => fetchSiweAccessToken(forceRefreshToken),
    [],
  )
  return { isLoading: false, isAuthenticated: session != null, fetchAccessToken }
}

/**
 * Read-only auth state, derived from the server-owned SIWE session — NO wagmi. This is
 * what keeps the wallet SDK off the critical path: the app can answer "who is signed in?"
 * from verified wallet metadata alone. `ConvexProviderWithAuth` separately requests a
 * short-lived memory-only bearer for authed calls. Signing in / connecting a wallet goes through
 * ConnectKit's own flow in `WalletControl`, so this hook has no wagmi dependency.
 *
 * The wallet-match check that previously gated `isSignedIn` on a live wagmi connection was
 * UI-only defense in depth; Convex is the real authority and rejects a token whose wallet
 * doesn't match. Dropping it lets a returning user's session read as signed-in immediately
 * from storage, with no wallet-reconnect flash.
 */
export function useSiweAuth() {
  // The server-owned session is the durable sign-in state; access tokens refresh on demand.
  const session = useLiveSiweToken()

  const authedWallet = session?.wallet ?? (IS_DEV_SHORTCUT_MODE ? TEST_MODE_WALLET_ADDRESS : null)
  const isSignedIn = IS_DEV_SHORTCUT_MODE || (session != null && authedWallet != null)

  return {
    authedWallet,
    isSignedIn,
  }
}
