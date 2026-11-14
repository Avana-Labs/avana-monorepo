import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

const { useQuery, testMode } = vi.hoisted(() => ({
  useQuery: vi.fn(),
  testMode: { audit: true, openGate: false },
}))

vi.mock("convex/react", () => ({ useQuery }))
// Stub the lazily-imported Convex prices module so React.lazy(() => import("./convex-token-prices"))
// never pulls the real convex/_generated graph. That dynamic import resolving AFTER the test env was
// torn down produced a flaky EnvironmentTeardownError under the full (unsharded) vitest run. The stub
// still calls the mocked useQuery when rendered, so the "did NOT open a subscription" assertions below
// stay meaningful — a regression that mounted it would still trip expect(useQuery).not.toHaveBeenCalled().
vi.mock("@/app/lib/prices/convex-token-prices", () => ({
  default: () => {
    useQuery()
    return null
  },
}))
vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({
  hasConvexClient: true,
}))
vi.mock("@/app/lib/test-mode", () => ({
  isLighthouseAuditMode: () => testMode.audit,
  shouldUseOpenGateSession: () => testMode.openGate,
}))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => ({ isSignedIn: true }),
}))

import { TokenPricesProvider } from "@/app/lib/prices/token-prices-context"

describe("TokenPricesProvider audit mode", () => {
  it("uses static labels without opening a live Convex subscription", () => {
    render(
      <TokenPricesProvider>
        <span>market content</span>
      </TokenPricesProvider>,
    )

    expect(screen.getByText("market content")).toBeInTheDocument()
    expect(useQuery).not.toHaveBeenCalled()
  })

  it("does not query Convex when the dev open gate uses local sessions", () => {
    testMode.audit = false
    testMode.openGate = true

    render(
      <TokenPricesProvider>
        <span>dev market content</span>
      </TokenPricesProvider>,
    )

    expect(screen.getByText("dev market content")).toBeInTheDocument()
    expect(useQuery).not.toHaveBeenCalled()
  })

  it("uses the server seed when a route owns its own nested Convex boundary", () => {
    testMode.audit = false
    testMode.openGate = false

    render(
      <TokenPricesProvider initialPrices={{ AAVE: 98.53 }} realtime={false}>
        <span>nested provider route</span>
      </TokenPricesProvider>,
    )

    expect(screen.getByText("nested provider route")).toBeInTheDocument()
    expect(useQuery).not.toHaveBeenCalled()
  })
})
