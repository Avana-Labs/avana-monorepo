"use client"

import dynamic from "next/dynamic"
import { usePathname } from "next/navigation"
import type { ReactNode } from "react"
import { PreferencesProfileSync } from "@/app/components/preferences-profile-sync"
import { TokenPricesProvider } from "@/app/lib/prices/token-prices-context"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { shouldUseOpenGateSession } from "@/app/lib/test-mode"

const AvanaSessionProviders = dynamic(() =>
  import("@/app/components/avana-session-providers").then((mod) => mod.AvanaSessionProviders),
)

const PRODUCT_RUNTIME_ROUTES = ["/actions", "/borrow", "/lend", "/swap", "/dashboard", "/ask"]

function needsProductRuntime(pathname: string) {
  // The guest Express workspace owns a swap-only session and activates the full
  // runtime on demand. Signed-in visitors still take the full runtime below.
  return PRODUCT_RUNTIME_ROUTES.some((route) => pathname === route || pathname.startsWith(`${route}/`))
}

export function ProductRuntimeProviders({
  children,
  initialTokenPrices,
}: {
  children: ReactNode
  initialTokenPrices?: Record<string, number>
}) {
  const pathname = usePathname()
  const { isSignedIn } = useSiweAuth()

  // Guest `/ask` owns a dedicated Convex auth boundary (SIWE or limited guest JWT).
  // Signed-in users keep the normal product runtime mounted under Ask so closing it
  // does not remount AvanaSessionProviders and flash a blank screen.
  if ((pathname === "/ask" || pathname.startsWith("/ask/")) && !isSignedIn) {
    return (
      <TokenPricesProvider initialPrices={initialTokenPrices} realtime={false}>
        {children}
      </TokenPricesProvider>
    )
  }

  if (!isSignedIn && !needsProductRuntime(pathname) && !(pathname === "/" && shouldUseOpenGateSession())) {
    // Still provide the server-seeded prices so any price consumer rendered outside the product
    // runtime resolves live values instead of the fixture. No Convex session is mounted on this
    // branch (guest Express or a route like `/support-center`), so realtime={false} avoids lazy-loading
    // convex/react for a subscription that would only throw for lack of a provider and fall back
    // to this same seed. Mirrors the guest `/ask` branch above.
    return (
      <TokenPricesProvider initialPrices={initialTokenPrices} realtime={false}>
        {children}
      </TokenPricesProvider>
    )
  }

  return (
    <AvanaSessionProviders>
      <PreferencesProfileSync />
      <TokenPricesProvider initialPrices={initialTokenPrices}>{children}</TokenPricesProvider>
    </AvanaSessionProviders>
  )
}
