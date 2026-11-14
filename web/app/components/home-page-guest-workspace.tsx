"use client"

import { lazy, Suspense, useState, type ComponentProps } from "react"
import { SwapSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import { GUEST_WALLET_ID } from "@/app/lib/data/wallet/profiles"
import { useSwapSession } from "@/app/lib/swap-system/use-swap-session"
import { HomeSwapAction } from "./home/home-swap-action"
import { HomeWorkspaceCard } from "./home/home-workspace-card"
import { ActionSessionLoading } from "./action-page/action-session-loading"

type HomeMode = ComponentProps<typeof HomeWorkspaceCard>["mode"]

const HomePageGuestRuntime = lazy(async () => ({
  default: (await import("./home-page-guest-runtime")).HomePageGuestRuntime,
}))

/** Use the existing swap engine with the same empty, non-persisted guest wallet. */
export function HomePageGuestWorkspace() {
  const swap = useSwapSession({ walletId: GUEST_WALLET_ID, persistState: false, seedDemoBalances: false })
  const [mode, setMode] = useState<HomeMode>("swap")

  // Once a product tab is requested, keep the normal workspace mounted so its
  // sessions and tab switching have exactly the same lifetime as before.
  if (mode !== "swap") {
    return (
      <Suspense
        fallback={
          <main className="bg-background">
            <h1 className="sr-only">Avana workspace</h1>
            <HomeWorkspaceCard mode={mode} onModeChange={setMode}>
              <ActionSessionLoading />
            </HomeWorkspaceCard>
          </main>
        }
      >
        <HomePageGuestRuntime initialMode={mode} swap={swap} />
      </Suspense>
    )
  }

  return (
    <main className="bg-background">
      <h1 className="sr-only">Avana workspace</h1>
      <HomeWorkspaceCard mode={mode} onModeChange={setMode}>
        <SwapSessionContext.Provider value={swap}>
          <HomeSwapAction />
        </SwapSessionContext.Provider>
      </HomeWorkspaceCard>
    </main>
  )
}
