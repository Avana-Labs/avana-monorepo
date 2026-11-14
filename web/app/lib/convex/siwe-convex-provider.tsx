"use client"

import type { ReactNode } from "react"
import { ConvexProviderWithAuth, ConvexReactClient, useConvex } from "convex/react"
import { useConvexSiweAuth } from "@/app/lib/siwe/use-siwe-auth"

const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL
let sharedClient: ConvexReactClient | null = null

/**
 * The ONE browser Convex client for SIWE-authenticated surfaces. Every provider that used to
 * `new ConvexReactClient(url)` at module scope opened its own WebSocket + auth handshake; the
 * gate, the liquidity ledger and the session tree now share a single socket and a single
 * `setAuth` so the second/third subtree to mount starts already authenticated.
 *
 * Lives in its own lazily-imported module so guests never pull `convex/react` into the layout
 * chunk — only signed-in branches import this file.
 */
export function getSiweConvexClient(): ConvexReactClient | null {
  if (!convexUrl || !/^https?:\/\//.test(convexUrl)) return null
  sharedClient ??= new ConvexReactClient(convexUrl)
  return sharedClient
}

/**
 * Mounts `ConvexProviderWithAuth` (SIWE JWT) over `children` unless an ancestor already
 * provides a Convex client — nesting a second provider would re-run auth and remount every
 * query subscription below it. Safe to wrap any signed-in subtree that calls `useQuery`.
 */
export function SiweConvexProvider({ children }: { children: ReactNode }) {
  // `useConvex` is typed non-null but is a bare `useContext` — undefined when no provider.
  const inherited = useConvex() as ConvexReactClient | undefined
  const client = getSiweConvexClient()
  if (inherited || !client) return <>{children}</>
  return (
    <ConvexProviderWithAuth client={client} useAuth={useConvexSiweAuth}>
      {children}
    </ConvexProviderWithAuth>
  )
}
