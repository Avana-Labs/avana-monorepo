import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { getFunctionName } from "convex/server"
import { afterEach, describe, expect, it, vi } from "vitest"

// hasConvexClient is decided at module load from NEXT_PUBLIC_CONVEX_URL; force it true so
// the provider mounts its Convex-backed subtree (where freshness is surfaced).
vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({
  hasConvexClient: true,
}))
vi.mock("@/app/lib/test-mode", () => ({
  isLighthouseAuditMode: () => false,
  shouldUseOpenGateSession: () => false,
}))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => ({ isSignedIn: true }),
}))

// Route each useQuery by its function path (convex refs are NOT identity-stable, so we
// can't compare by reference). getPriceSnapshot drives prices and freshness together.
const statusResult = { current: undefined as unknown }
vi.mock("convex/react", () => ({
  useQuery: (ref: unknown) => {
    const name = getFunctionName(ref as never)
    const value = name === "prices:getPriceSnapshot" ? statusResult.current : undefined
    // Convex's real useQuery re-throws server errors during render; model that so we can
    // assert the provider's error boundary keeps a prices outage from crashing the app.
    if (value instanceof Error) throw value
    return value
  },
}))

import { TokenPricesProvider, usePriceFreshness } from "@/app/lib/prices/token-prices-context"

const STALE_AFTER = 3 * 60 * 60 * 1000

function Probe() {
  const { stale, updatedAt } = usePriceFreshness()
  return (
    <div>
      <span data-testid="stale">{String(stale)}</span>
      <span data-testid="updatedAt">{String(updatedAt)}</span>
    </div>
  )
}

function renderWithStatus(status: unknown) {
  statusResult.current = status === undefined || status instanceof Error ? status : { prices: [], status }
  render(
    <TokenPricesProvider>
      <Probe />
    </TokenPricesProvider>,
  )
}

afterEach(() => {
  cleanup()
  statusResult.current = undefined
})

describe("usePriceFreshness", () => {
  it("does not flag stale while the status query is still loading", () => {
    renderWithStatus(undefined)
    expect(screen.getByTestId("stale").textContent).toBe("false")
  })

  it("reflects a fresh oracle (not stale)", async () => {
    // New contract: the query returns only updatedAt/staleAfterMs; the client derives stale
    // from a ticking clock. A just-refreshed row is within the window.
    const updatedAt = Date.now()
    renderWithStatus({ updatedAt, staleAfterMs: STALE_AFTER, count: 5 })
    await waitFor(() => expect(screen.getByTestId("updatedAt").textContent).toBe(String(updatedAt)))
    expect(screen.getByTestId("stale").textContent).toBe("false")
  })

  it("flags staleness when the cron has stalled (derived from wall clock)", async () => {
    // Last refresh is older than the stale window → the client derivation flags it, even
    // though the query result itself never changed (the whole point of moving this client-side).
    renderWithStatus({
      updatedAt: Date.now() - (STALE_AFTER + 60_000),
      staleAfterMs: STALE_AFTER,
      count: 5,
    })
    await waitFor(() => expect(screen.getByTestId("stale").textContent).toBe("true"))
  })

  it("flags staleness when no prices have ever been served", async () => {
    renderWithStatus({ updatedAt: null, staleAfterMs: STALE_AFTER, count: 0 })
    await waitFor(() => expect(screen.getByTestId("stale").textContent).toBe("true"))
  })

  it("degrades to defaults (no crash) when the status query errors", async () => {
    // Reproduces the live incident: `getPriceStatus` missing on a stale Convex deploy, so
    // useQuery re-throws. The provider sits above the root gate, so without a boundary this
    // would escalate to the global "Something went wrong" screen. Assert children still
    // render with neutral freshness instead.
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    try {
      renderWithStatus(new Error("[CONVEX Q(prices:getPriceSnapshot)] Server Error"))
      await waitFor(() => expect(screen.getByTestId("updatedAt").textContent).toBe("null"))
      expect(screen.getByTestId("stale").textContent).toBe("false")
    } finally {
      errorSpy.mockRestore()
    }
  })
})
