import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AvanaSessionProviders } from "../avana-session-providers"
import { GUEST_WALLET_ID } from "@/app/lib/data/wallet/profiles"

const mocks = vi.hoisted(() => ({
  convexAuthenticated: false,
  openGate: false,
  playwright: false,
  openGateReady: true,
  localProps: null as Record<string, unknown> | null,
  liquidityLive: undefined as boolean | undefined,
  siwe: {
    authedWallet: "0x1111111111111111111111111111111111111111",
    isSignedIn: true,
  },
}))

vi.mock("convex/react", () => ({
  useConvexAuth: () => ({
    isAuthenticated: mocks.convexAuthenticated,
    isLoading: !mocks.convexAuthenticated,
  }),
  ConvexReactClient: class {
    constructor() {}
  },
  useConvex: () => undefined,
  ConvexProviderWithAuth: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => mocks.siwe,
  useConvexSiweAuth: () => ({ isLoading: false, isAuthenticated: false, fetchAccessToken: async () => null }),
}))

vi.mock("@/app/lib/siwe/use-open-gate-auth-bootstrap", () => ({
  useOpenGateAuthBootstrap: () => ({ ready: mocks.openGateReady, error: null }),
}))

vi.mock("@/app/lib/test-mode", () => ({
  isPlaywrightTestMode: () => mocks.playwright,
  shouldUseOpenGateSession: () => mocks.openGate,
  TEST_MODE_WALLET_ADDRESS: "0x2222222222222222222222222222222222222222",
}))

vi.mock("@/app/lib/convex/siwe-convex-provider", () => ({
  getSiweConvexClient: () => null,
  SiweConvexProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({
  hasConvexClient: true,
  MarketLiquidityProvider: ({ children, live }: { children: React.ReactNode; live?: boolean }) => {
    mocks.liquidityLive = live
    return <>{children}</>
  },
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  AvanaSessionsProvider: ({ children, ...props }: { children: React.ReactNode }) => {
    mocks.localProps = props
    return <div data-testid="local-session">{children}</div>
  },
}))

vi.mock("@/app/lib/avana-session/convex-session-provider", () => ({
  ConvexSessionProvider: ({ children }: { children: React.ReactNode }) =>
    mocks.convexAuthenticated ? (
      <div data-testid="convex-session">{children}</div>
    ) : (
      <div aria-label="Authenticating wallet session">
        <div data-testid="local-session">{children}</div>
      </div>
    ),
}))

describe("AvanaSessionProviders", () => {
  afterEach(() => {
    cleanup()
  })

  beforeEach(() => {
    mocks.convexAuthenticated = false
    mocks.siwe.isSignedIn = true
    mocks.openGate = false
    mocks.playwright = false
    mocks.openGateReady = true
    mocks.localProps = null
    mocks.liquidityLive = undefined
  })

  it("gives a guest an empty, non-persisted wallet on the live market feed (no demo portfolio)", () => {
    mocks.siwe.isSignedIn = false

    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    expect(screen.getByText("App content")).toBeInTheDocument()
    expect(mocks.localProps).toMatchObject({
      walletId: GUEST_WALLET_ID,
      sessionSource: "convex",
      persistLocalState: false,
      persistUmbrellaState: false,
    })
    expect(mocks.liquidityLive).toBe(true)
  })

  it("does not mount wallet queries before Convex confirms the SIWE token", async () => {
    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    expect(await screen.findByLabelText("Authenticating wallet session")).toBeInTheDocument()
    // Instant Paint: product chrome stays mounted on the local session while Convex auth settles.
    expect(screen.getByText("App content")).toBeInTheDocument()
    expect(screen.queryByTestId("convex-session")).not.toBeInTheDocument()
  })

  it("mounts the wallet session after Convex confirms authentication", async () => {
    mocks.convexAuthenticated = true

    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    expect(await screen.findByTestId("convex-session")).toHaveTextContent("App content")
  })

  it("open-gate waits for bootstrap then mounts the authenticated Convex wallet session", async () => {
    mocks.openGate = true
    mocks.siwe.isSignedIn = false
    mocks.openGateReady = true
    mocks.convexAuthenticated = true

    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    await waitFor(() => {
      expect(screen.getByTestId("convex-session")).toHaveTextContent("App content")
    })
    expect(screen.queryByTestId("local-session")).not.toBeInTheDocument()
  })

  it("open-gate paints product chrome on the local session until the bootstrap JWT is ready", async () => {
    mocks.openGate = true
    mocks.openGateReady = false
    mocks.siwe.isSignedIn = false

    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    // Instant Paint: never blank — local session carries chrome while JWT mints.
    expect(screen.getByTestId("local-session")).toBeInTheDocument()
    expect(screen.getByText("App content")).toBeInTheDocument()
    expect(screen.queryByTestId("convex-session")).not.toBeInTheDocument()
  })

  it("keeps Playwright test mode on the local session without Convex auth bootstrap", async () => {
    mocks.playwright = true
    mocks.openGate = true
    mocks.siwe.isSignedIn = false

    render(
      <AvanaSessionProviders>
        <div>App content</div>
      </AvanaSessionProviders>,
    )

    expect(screen.getByTestId("local-session")).toHaveTextContent("App content")
    expect(screen.queryByTestId("convex-session")).not.toBeInTheDocument()
  })
})
