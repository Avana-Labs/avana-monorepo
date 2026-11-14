import { render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import { describe, expect, it, vi } from "vitest"
import { SwapSessionContext, useSwapSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import type { SwapSession } from "@/app/lib/avana-session/avana-sessions-provider"

// The full session tree creates its own guest swap session; the workspace must still see the
// guest's existing one so simulated swaps made before opening another tab are kept.
vi.mock("@/app/components/avana-session-providers", () => ({
  AvanaSessionProviders: ({ children }: { children: ReactNode }) => (
    <SwapSessionContext.Provider value={{ walletId: "fresh-runtime-swap" } as unknown as SwapSession}>
      {children}
    </SwapSessionContext.Provider>
  ),
}))
vi.mock("@/app/components/home-page-workspace-runtime", () => ({
  HomePageWorkspaceRuntime: () => {
    const swap = useSwapSessionContext() as unknown as { walletId: string }
    return <div data-testid="swap-session">{swap.walletId}</div>
  },
}))

import { HomePageGuestRuntime } from "../home-page-guest-runtime"

describe("HomePageGuestRuntime", () => {
  it("keeps the guest's existing swap session when the full runtime mounts", () => {
    const guestSwap = { walletId: "guest-swap" } as unknown as SwapSession
    render(<HomePageGuestRuntime initialMode="borrow" swap={guestSwap} />)
    expect(screen.getByTestId("swap-session")).toHaveTextContent("guest-swap")
  })
})
