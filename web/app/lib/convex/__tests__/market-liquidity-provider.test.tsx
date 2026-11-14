import type { ReactNode } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MarketLiquidityProvider, useMarketLiquidity } from "@/app/lib/convex/market-liquidity-provider"

// Simulate Convex being unreachable (useQuery never resolves) so the provider
// must use its in-session local fallback ledger.
vi.mock("convex/react", () => ({
  ConvexProvider: ({ children }: { children: ReactNode }) => <>{children}</>,
  ConvexReactClient: class {},
  useQuery: () => undefined,
  useMutation: () => () => Promise.resolve(),
}))

function Probe() {
  const { deltas, connected, recordDelta } = useMarketLiquidity()
  return (
    <div>
      <span data-testid="connected">{String(connected)}</span>
      <span data-testid="borrowed">{deltas.get("usdc")?.borrowedDeltaUsd ?? 0}</span>
      <span data-testid="supplied">{deltas.get("eth-usdc")?.suppliedDeltaUsd ?? 0}</span>
      <button type="button" onClick={() => recordDelta({ marketSlug: "usdc", borrowedDeltaUsd: 250 })}>
        borrow
      </button>
      <button type="button" onClick={() => recordDelta({ marketSlug: "usdc", borrowedDeltaUsd: -100 })}>
        repay
      </button>
      <button type="button" onClick={() => recordDelta({ marketSlug: "eth-usdc", suppliedDeltaUsd: 500 })}>
        supply
      </button>
    </div>
  )
}

describe("MarketLiquidityProvider local fallback", () => {
  it("records and aggregates deltas in-session when Convex is unreachable", () => {
    render(
      <MarketLiquidityProvider>
        <Probe />
      </MarketLiquidityProvider>,
    )

    expect(screen.getByTestId("connected").textContent).toBe("false")
    expect(screen.getByTestId("borrowed").textContent).toBe("0")

    fireEvent.click(screen.getByText("borrow"))
    expect(screen.getByTestId("borrowed").textContent).toBe("250")

    // Deltas accumulate per slug...
    fireEvent.click(screen.getByText("repay"))
    expect(screen.getByTestId("borrowed").textContent).toBe("150")

    // ...and supplied/borrowed are tracked independently per slug.
    fireEvent.click(screen.getByText("supply"))
    expect(screen.getByTestId("supplied").textContent).toBe("500")
    expect(screen.getByTestId("borrowed").textContent).toBe("150")
  })
})
