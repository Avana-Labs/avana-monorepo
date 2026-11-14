import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { getFunctionName } from "convex/server"
import { afterEach, describe, expect, it, vi } from "vitest"

// Prices are public data: the provider must open the live subscription even when the
// visitor is signed OUT. Force a Convex client, non-test surface, and no sign-in.
vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({
  hasConvexClient: true,
}))
vi.mock("@/app/lib/test-mode", () => ({
  isLighthouseAuditMode: () => false,
  shouldUseOpenGateSession: () => false,
}))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => ({ isSignedIn: false }),
}))

// Route useQuery by function path (convex refs are not identity-stable). The price
// snapshot carries a live AAVE quote so we can assert it flows to consumers.
const snapshot = { current: undefined as unknown }
vi.mock("convex/react", () => ({
  useQuery: (ref: unknown) => {
    const name = getFunctionName(ref as never)
    return name === "prices:getPriceSnapshot" ? snapshot.current : undefined
  },
}))

import { TokenPricesProvider, usePriceFor } from "@/app/lib/prices/token-prices-context"

function Probe() {
  const priceFor = usePriceFor()
  return <span data-testid="aave">{String(priceFor("AAVE"))}</span>
}

afterEach(() => {
  cleanup()
  snapshot.current = undefined
  vi.useRealTimers()
})

describe("TokenPricesProvider public (signed-out) sessions", () => {
  it("opens the live subscription and surfaces oracle prices without sign-in", async () => {
    snapshot.current = {
      prices: [{ symbol: "AAVE", priceUsd: 88.25, updatedAt: Date.now(), status: "fresh" }],
      status: { updatedAt: Date.now(), staleAfterMs: 3 * 60 * 60 * 1000, count: 1 },
    }

    render(
      <TokenPricesProvider>
        <Probe />
      </TokenPricesProvider>,
    )

    // If the sign-in gate were still in place the lazy Convex subtree would never mount
    // and this would stay "undefined"; ungated, the public quote flows through.
    await waitFor(() => expect(screen.getByTestId("aave").textContent).toBe("88.25"))
  })

  it("ages out a quote when the Convex subscription stops updating", async () => {
    vi.useFakeTimers()
    const now = new Date("2026-08-27T12:00:00Z")
    vi.setSystemTime(now)
    snapshot.current = {
      prices: [{ symbol: "AAVE", priceUsd: 88.25, updatedAt: now.getTime(), status: "fresh" }],
      status: {
        updatedAt: now.getTime(),
        staleAfterMs: 15 * 60 * 1000,
        invalidAfterMs: 45 * 60 * 1000,
        count: 1,
      },
    }

    render(
      <TokenPricesProvider initialPrices={{ aave: 88.25 }}>
        <Probe />
      </TokenPricesProvider>,
    )

    expect(screen.getByTestId("aave").textContent).toBe("88.25")
    await vi.advanceTimersByTimeAsync(46 * 60 * 1000)
    expect(screen.getByTestId("aave").textContent).not.toBe("88.25")
  })
})
