import type { ReactNode } from "react"
import { useEffect, useState } from "react"
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { HomePageClient } from "@/app/components/home-page-client"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { selectAllAvailableCollateralPools, selectBorrowCollateralPools } from "@/app/lib/borrow-system/selectors"

const walletId = "demo-wallet"
let state = buildMockBorrowSystemState(walletId)
const runtimeProps: Array<{ walletId?: string }> = []
const auth = vi.hoisted(() => ({ isSignedIn: true }))

vi.mock("@/app/lib/test-mode", () => ({ shouldUseOpenGateSession: () => false }))
vi.mock("@/app/components/home-page-guest-workspace", () => ({
  HomePageGuestWorkspace: () => <div data-testid="guest-swap-workspace" />,
}))

vi.mock("next/dynamic", () => ({
  default: (loader: () => Promise<{ default: (props: Record<string, unknown>) => ReactNode }>) =>
    function DynamicTestComponent(props: Record<string, unknown>) {
      const [Component, setComponent] = useState<((props: Record<string, unknown>) => ReactNode) | null>(null)
      useEffect(() => {
        let cancelled = false
        void loader().then((mod) => {
          if (!cancelled) setComponent(() => mod.default)
        })
        return () => {
          cancelled = true
        }
      }, [])
      if (!Component) return null
      return <Component {...props} />
    },
}))

vi.mock("@/app/components/home-page-workspace-runtime", () => ({
  HomePageWorkspaceRuntime: function MockHomeWorkspaceRuntime(props: { walletId?: string }) {
    runtimeProps.push(props)
    const [mode, setMode] = useState("borrow")
    return (
      <div data-testid="home-workspace-card">
        {["Borrow", "Repay", "Claim", "Remove"].map((label) => (
          <button key={label} type="button" role="tab" onClick={() => setMode(label.toLowerCase())}>
            {label}
          </button>
        ))}
        {mode === "borrow" ? (
          <div data-testid="embedded-borrow-action-borrow" data-embedded="true" data-layout="home" />
        ) : null}
        {mode === "repay" ? (
          <div data-testid="embedded-borrow-action-repay" data-embedded="true" data-layout="home" />
        ) : null}
        {mode === "claim" ? (
          <div data-testid="embedded-borrow-action-claim" data-embedded="true" data-layout="home" />
        ) : null}
        {mode === "remove" ? (
          <div
            data-testid="embedded-borrow-action-remove"
            data-embedded="true"
            data-layout="home"
            data-initial-amount=""
          />
        ) : null}
      </div>
    )
  },
}))

vi.mock("@/app/components/action-page/borrow-action-page-client", () => ({
  BorrowActionPageClient: ({
    kind,
    embedded,
    layout,
    initialAmount,
  }: {
    kind: string
    embedded?: boolean
    layout?: string
    initialAmount?: string
  }) => (
    <div
      data-testid={`embedded-borrow-action-${kind}`}
      data-embedded={embedded ? "true" : "false"}
      data-layout={layout ?? "default"}
      data-initial-amount={initialAmount ?? ""}
    />
  ),
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  AvanaSessionsProvider: ({ children }: { children: ReactNode }) => <>{children}</>,
  useBorrowSessionContext: () => ({
    state,
    collateralPools: selectBorrowCollateralPools(state, walletId),
    availableCollateralPools: selectAllAvailableCollateralPools(state, walletId),
  }),
}))

vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => ({ isSignedIn: auth.isSignedIn, address: null }),
}))

describe("HomePageClient", () => {
  afterEach(() => cleanup())

  beforeEach(() => {
    state = buildMockBorrowSystemState(walletId)
    auth.isSignedIn = true
  })

  it("embeds borrow actions in the home workspace card", async () => {
    render(<HomePageClient />)

    expect(await screen.findByTestId("home-workspace-card")).toBeInTheDocument()
    const borrowAction = await screen.findByTestId("embedded-borrow-action-borrow")
    expect(borrowAction).toHaveAttribute("data-embedded", "true")
    expect(borrowAction).toHaveAttribute("data-layout", "home")
  }, 10_000)

  it("uses the swap-only workspace for guests without mounting the full runtime", async () => {
    auth.isSignedIn = false
    runtimeProps.length = 0
    render(<HomePageClient />)
    await screen.findByTestId("guest-swap-workspace")
    expect(runtimeProps).toHaveLength(0)
  })

  it("switches tabs to embedded repay, claim, and remove actions", async () => {
    render(<HomePageClient />)
    const card = await screen.findByTestId("home-workspace-card")

    fireEvent.click(within(card).getByRole("tab", { name: "Repay" }))
    expect(await screen.findByTestId("embedded-borrow-action-repay")).toBeInTheDocument()

    fireEvent.click(within(card).getByRole("tab", { name: "Claim" }))
    expect(await screen.findByTestId("embedded-borrow-action-claim")).toBeInTheDocument()

    fireEvent.click(within(card).getByRole("tab", { name: "Remove" }))
    expect(await screen.findByTestId("embedded-borrow-action-remove")).toHaveAttribute("data-initial-amount", "")
  })
})
