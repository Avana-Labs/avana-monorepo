import { fireEvent, render, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import {
  AMOUNT_SIGN_BY_KIND,
  inferActivityTokenSymbol,
  inferActivityTokenSymbols,
  RecentActivity,
} from "@/app/dashboard/recent-activity"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"

const push = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  usePathname: () => "/",
  useSearchParams: () => new URLSearchParams(),
}))

vi.mock("convex/react", () => ({
  useQuery: () => undefined,
  useConvexAuth: () => ({ isAuthenticated: false, isLoading: false }),
}))

function makeRow(overrides: Partial<PortfolioActivityRow> & { id: string; txHash: string }): PortfolioActivityRow {
  return {
    at: "2026-06-19T12:00:00.000Z",
    product: "lend",
    kind: "supply",
    status: "confirmed",
    amountUsd: 1000,
    primaryLabel: "Simulated deposit",
    secondaryLabel: "0.4 ETH",
    ...overrides,
  }
}

describe("RecentActivity whole-row navigation", () => {
  beforeEach(() => {
    push.mockClear()
  })

  it("routes a genuinely on-chain row to Etherscan instead of the in-app router", () => {
    const realHash = `0x${"b".repeat(64)}`
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null)
    const { container } = render(
      <DisplayPreferencesProvider>
        <RecentActivity rows={[makeRow({ id: "real-1", txHash: realHash })]} />
      </DisplayPreferencesProvider>,
    )
    const row = container.querySelector('[role="link"]') as HTMLElement
    fireEvent.click(row)
    expect(push).not.toHaveBeenCalled()
    expect(openSpy).toHaveBeenCalledWith(`https://etherscan.io/tx/${realHash}`, "_blank", "noopener,noreferrer")
    openSpy.mockRestore()
  })

  it("renders a compact feed without Product, Status, or Txn columns", () => {
    const { container } = render(
      <DisplayPreferencesProvider>
        <RecentActivity
          rows={[
            makeRow({
              id: "sim-1",
              txHash: "sim-abc",
              kind: "stake",
              product: "umbrella",
              primaryLabel: "Staked WETH",
              secondaryLabel: "3.4747 WETH",
              amountUsd: 6700,
            }),
          ]}
        />
      </DisplayPreferencesProvider>,
    )
    const view = within(container)
    expect(view.getByText("Staked WETH")).toBeInTheDocument()
    expect(view.getByText(/Stake · 3\.4747 WETH ·/)).toBeInTheDocument()
    expect(view.getByText("-$6.7K")).toBeInTheDocument()
    expect(view.queryByText("Umbrella")).not.toBeInTheDocument()
    expect(view.queryByText("Confirmed")).not.toBeInTheDocument()
    expect(view.queryByText(/sim-abc/)).not.toBeInTheDocument()
    expect(view.queryByText("Product")).not.toBeInTheDocument()
    expect(view.queryByText("Status")).not.toBeInTheDocument()
    expect(view.queryByText("Txn")).not.toBeInTheDocument()
  })

  it("contains the feed in a vertically scrollable panel", () => {
    const { container } = render(
      <DisplayPreferencesProvider>
        <RecentActivity
          rows={Array.from({ length: 12 }, (_, index) =>
            makeRow({ id: `sim-${index}`, txHash: `sim-${index}`, primaryLabel: `Row ${index}` }),
          )}
        />
      </DisplayPreferencesProvider>,
    )
    const panel = container.querySelector('[role="region"]')
    expect(panel).toBeTruthy()
    expect(panel?.className).toMatch(/max-h-80/)
    expect(panel?.className).toMatch(/lg:max-h-\[560px\]/)
    expect(panel?.className).toMatch(/overflow-y-auto/)
    expect(panel?.className).toMatch(/border/)
  })

  it("infers both constituent icons for pool collateral activity", () => {
    expect(
      inferActivityTokenSymbols(
        makeRow({
          id: "pool-withdraw",
          txHash: "sim-pool-withdraw",
          product: "pool",
          kind: "withdraw",
          marketId: "BAL-WEIGHTED-80-20-AURA-WETH",
          primaryLabel: "AURA / WETH",
          secondaryLabel: "Withdraw",
        }),
      ),
    ).toEqual(["AURA", "WETH"])
  })
})

describe("RecentActivity amount sign convention (#F2)", () => {
  it("assigns a consistent cash-flow sign to every action kind", () => {
    const cashIn: PortfolioActivityRow["kind"][] = ["borrow", "withdraw", "claim", "unstake", "reduce", "close"]
    const cashOut: PortfolioActivityRow["kind"][] = [
      "supply",
      "repay",
      "pledge",
      "stake",
      "open",
      "addCollateral",
      "liquidation",
    ]
    const neutral: PortfolioActivityRow["kind"][] = ["swap", "startCooldown", "rebalance", "interest"]

    for (const kind of cashIn) expect(AMOUNT_SIGN_BY_KIND[kind]).toBe(1)
    for (const kind of cashOut) expect(AMOUNT_SIGN_BY_KIND[kind]).toBe(-1)
    for (const kind of neutral) expect(AMOUNT_SIGN_BY_KIND[kind]).toBe(0)

    expect(AMOUNT_SIGN_BY_KIND.borrow).toBe(1)
    expect(AMOUNT_SIGN_BY_KIND.withdraw).toBe(1)
    expect(AMOUNT_SIGN_BY_KIND.repay).toBe(-1)
    expect(AMOUNT_SIGN_BY_KIND.pledge).toBe(-1)
  })

  it("renders the sign from the kind, not the raw amount's stored sign", () => {
    const { container } = render(
      <DisplayPreferencesProvider>
        <RecentActivity
          rows={[
            makeRow({ id: "borrow", txHash: "sim-borrow", product: "borrow", kind: "borrow", amountUsd: 5 }),
            makeRow({ id: "repay", txHash: "sim-repay", product: "borrow", kind: "repay", amountUsd: 40 }),
            makeRow({ id: "swap", txHash: "sim-swap", product: "swap", kind: "swap", amountUsd: 12 }),
          ]}
        />
      </DisplayPreferencesProvider>,
    )
    const view = within(container)
    expect(view.getByText("+$5")).toBeInTheDocument()
    expect(view.getByText("-$40")).toBeInTheDocument()
    expect(view.getByText("$12")).toBeInTheDocument()
    expect(view.queryByText("+$12")).not.toBeInTheDocument()
    expect(view.queryByText("-$12")).not.toBeInTheDocument()
  })

  it("renders onboarding grants as received USD instead of spent AVA", () => {
    const { container } = render(
      <DisplayPreferencesProvider>
        <RecentActivity
          rows={[
            makeRow({
              id: "onboarding-claim",
              txHash: "sim-onboarding",
              product: "onboarding",
              kind: "claim",
              amountUsd: 1_000_000,
              primaryLabel: "Sandbox portfolio funded",
              secondaryLabel: "Onboarding grant",
            }),
          ]}
        />
      </DisplayPreferencesProvider>,
    )
    const view = within(container)
    expect(view.getByText("+$1.0M")).toBeInTheDocument()
    expect(view.queryByText(/AVA/)).not.toBeInTheDocument()
  })
})
