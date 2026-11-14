"use client"

import { useConvexAuth } from "convex/react"

/**
 * Args for an auth-required Convex query, or "skip" until Convex has authenticated.
 *
 * Wallet-scoped reads call requireSandboxWallet, which THROWS for an unauthenticated request,
 * and useQuery re-throws that during render — taking the page to its error boundary. That
 * happens whenever a wallet id is known before the JWT is attached: the local fallback session
 * while auth mints, a token refresh, or Playwright test mode against a real backend.
 * Pass `null` when the query shouldn't run for other reasons (e.g. no wallet yet).
 */
export function useAuthedQueryArgs<Args extends Record<string, unknown>>(args: Args | null): Args | "skip" {
  const { isAuthenticated } = useConvexAuth()
  return args && isAuthenticated ? args : "skip"
}
