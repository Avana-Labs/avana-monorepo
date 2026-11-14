import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  pathname: "/",
  auth: { isSignedIn: false, authedWallet: undefined as string | undefined },
  gate: undefined as { onboardingStep: string; economy: object } | undefined,
}))

vi.mock("next/navigation", () => ({ usePathname: () => state.pathname, useRouter: () => ({ push: vi.fn() }) }))
vi.mock("next/dynamic", () => ({ default: () => () => <div data-testid="signed-in-host" /> }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useSiweAuth: () => state.auth }))
vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({ hasConvexClient: true }))
vi.mock("@/app/lib/test-mode", () => ({ IS_DEV_SHORTCUT_MODE: false }))
vi.mock("@/app/lib/convex/siwe-convex-provider", () => ({
  SiweConvexProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))
vi.mock("convex/react", () => ({
  useConvexAuth: () => ({ isAuthenticated: true }),
  useQuery: () => state.gate,
}))
vi.mock("@/convex/_generated/api", () => ({ api: { sandbox: { onboarding: { getOnboardingGateState: {} } } } }))
vi.mock("../guest-onboarding-flow", () => ({ GuestOnboardingFlow: () => <div data-testid="guest-onboarding" /> }))
vi.mock("../onboarding-flow", () => ({
  OnboardingFlow: () => <div data-testid="wallet-onboarding" />,
  OnboardingUnavailable: () => null,
}))

import { SandboxGate } from "../sandbox-gate"
import { SignedInSandboxGate } from "../signed-in-sandbox-gate"
import { useTransactAccess } from "@/app/lib/transact-access"

function AccessProbe() {
  return <div data-testid="access">{useTransactAccess()}</div>
}

afterEach(() => {
  cleanup()
  state.auth = { isSignedIn: false, authedWallet: undefined }
  state.gate = undefined
})

const page = <div data-testid="page" />

describe("SandboxGate for guests", () => {
  it.each(["/", "/borrow", "/lend/markets/usdc", "/multiply/markets/eth", "/swap", "/support-center"])(
    "renders %s for a guest",
    (pathname) => {
      state.pathname = pathname
      render(<SandboxGate>{page}</SandboxGate>)
      expect(screen.getByTestId("page")).toBeTruthy()
      expect(screen.queryByTestId("guest-onboarding")).toBeNull()
    },
  )

  it.each(["/dashboard", "/umbrella"])("shows the onboarding flow on %s", (pathname) => {
    state.pathname = pathname
    render(<SandboxGate>{page}</SandboxGate>)
    expect(screen.getByTestId("guest-onboarding")).toBeTruthy()
    expect(screen.queryByTestId("page")).toBeNull()
  })
})

describe("SignedInSandboxGate for a wallet still onboarding", () => {
  const notDone = () => {
    state.gate = { onboardingStep: "eligible", economy: {} }
  }

  it("keeps an open route's page mounted and hides the onboarding flow", () => {
    notDone()
    state.pathname = "/borrow"
    render(
      <SignedInSandboxGate wallet="0xabc" optimistic={false}>
        {page}
      </SignedInSandboxGate>,
    )
    expect(screen.getByTestId("page")).toBeTruthy()
    expect(screen.queryByTestId("wallet-onboarding")).toBeNull()
  })

  it("shows the onboarding flow instead of the dashboard", () => {
    notDone()
    state.pathname = "/dashboard"
    render(
      <SignedInSandboxGate wallet="0xabc" optimistic={false}>
        {page}
      </SignedInSandboxGate>,
    )
    expect(screen.getByTestId("wallet-onboarding")).toBeTruthy()
    expect(screen.queryByTestId("page")).toBeNull()
  })

  it("renders the dashboard once onboarding is done", () => {
    state.gate = { onboardingStep: "done", economy: {} }
    state.pathname = "/dashboard"
    render(
      <SignedInSandboxGate wallet="0xabc" optimistic={false}>
        {page}
      </SignedInSandboxGate>,
    )
    expect(screen.getByTestId("page")).toBeTruthy()
  })
})

describe("transact access", () => {
  it("marks a guest on an open route", () => {
    state.pathname = "/borrow"
    render(
      <SandboxGate>
        <AccessProbe />
      </SandboxGate>,
    )
    expect(screen.getByTestId("access")).toHaveTextContent("guest")
  })

  it("marks a signed-in wallet that has not onboarded", () => {
    state.gate = { onboardingStep: "eligible", economy: {} }
    state.pathname = "/borrow"
    render(
      <SignedInSandboxGate wallet="0xabc" optimistic={false}>
        <AccessProbe />
      </SignedInSandboxGate>,
    )
    expect(screen.getByTestId("access")).toHaveTextContent("needs-onboarding")
  })

  it("marks an onboarded wallet ready", () => {
    state.gate = { onboardingStep: "done", economy: {} }
    state.pathname = "/borrow"
    render(
      <SignedInSandboxGate wallet="0xabc" optimistic={false}>
        <AccessProbe />
      </SignedInSandboxGate>,
    )
    expect(screen.getByTestId("access")).toHaveTextContent("ready")
  })
})
