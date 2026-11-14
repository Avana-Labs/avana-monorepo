"use client"

import { useContext, type ComponentProps } from "react"
import { SwapSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import type { SwapSession } from "@/app/lib/avana-session/avana-sessions-provider"
import { TokenPricesContext, TokenPricesProvider } from "@/app/lib/prices/token-prices-context"
import { AvanaSessionProviders } from "./avana-session-providers"
import { HomePageWorkspaceRuntime } from "./home-page-workspace-runtime"

/** Loaded only when a guest asks for Borrow, Repay, Claim, or Remove. */
export function HomePageGuestRuntime({
  initialMode,
  swap,
}: {
  initialMode: NonNullable<ComponentProps<typeof HomePageWorkspaceRuntime>["initialMode"]>
  /** The guest's swap session from the swap-only workspace, so its simulated swaps survive the upgrade. */
  swap: SwapSession
}) {
  const initialPrices = useContext(TokenPricesContext)
  return (
    <AvanaSessionProviders>
      <TokenPricesProvider initialPrices={initialPrices}>
        <SwapSessionContext.Provider value={swap}>
          <HomePageWorkspaceRuntime initialMode={initialMode} />
        </SwapSessionContext.Provider>
      </TokenPricesProvider>
    </AvanaSessionProviders>
  )
}
