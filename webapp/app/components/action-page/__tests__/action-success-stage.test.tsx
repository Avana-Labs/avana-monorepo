import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"

// jsdom does not advance performance.now() inside its rAF loop, so mount
// animations (AnimatedTextValue) never settle. Drive rAF with a far-future
// timestamp so the animation completes in a single frame.
beforeEach(() => {
  vi.stubGlobal(
    "requestAnimationFrame",
    (cb: FrameRequestCallback) => setTimeout(() => cb(performance.now() + 100000), 0) as unknown as number,
  )
  vi.stubGlobal("cancelAnimationFrame", (id: number) => clearTimeout(id as unknown as ReturnType<typeof setTimeout>))
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe("ActionMetricsBlock", () => {
  it("renders health factor rows with heart styling on after value", async () => {
    render(
      <ActionMetricsBlock
        rows={[
          {
            id: "health-factor",
            label: "Health factor",
            value: "6.59 → 1.08",
            before: "6.59",
            after: "1.08",
            tone: "warning",
          },
        ]}
      />,
    )

    expect(screen.getByTestId("action-health-factor-bar")).toBeInTheDocument()
    expect(screen.getByTestId("action-health-factor-card")).toBeInTheDocument()
    // The after value animates from the before value on mount, so wait for it to settle.
    await waitFor(() => expect(screen.getAllByText("1.08").length).toBeGreaterThan(0))
  })
})

describe("ActionSuccessStage", () => {
  it("renders receipt card when receipt context is provided", async () => {
    render(
      <DisplayPreferencesProvider>
        <ActionSuccessStage
          closeHref="/borrow"
          success={{
            title: "Borrow successful",
            description: "$1,000 processed.",
            receiptHash: "sim-123",
            metrics: [],
            primaryCtaLabel: "View borrow dashboard",
            primaryCtaHref: "/borrow",
            secondaryCtaLabel: "Done",
            receiptContext: {
              verb: "Borrow",
              amountLabel: "1000.00 USDC",
              rateLabel: "Borrow APY",
              rateValue: "7.04%",
              marketValue: "USDC · Core",
            },
          }}
        />
      </DisplayPreferencesProvider>,
    )

    expect(screen.getByTestId("action-success-stage")).toBeInTheDocument()
    expect(screen.getByText("Confirmed")).toBeInTheDocument()
    // amountLabel animates on mount; wait for the final value to settle.
    await waitFor(() => expect(screen.getByText("1000.00 USDC")).toBeInTheDocument())
  })

  it("omits the rate receipt row when the action has no rate (pledge)", async () => {
    render(
      <DisplayPreferencesProvider>
        <ActionSuccessStage
          closeHref="/borrow"
          success={{
            title: "Pledge successful",
            description: "1.000000 ETH processed.",
            receiptHash: "sim-456",
            metrics: [],
            primaryCtaLabel: "View borrow dashboard",
            primaryCtaHref: "/borrow",
            secondaryCtaLabel: "Done",
            receiptContext: {
              verb: "Pledge",
              amountLabel: "1.000000 ETH",
              rateLabel: "",
              rateValue: "",
              marketValue: "ETH · USDC",
            },
          }}
        />
      </DisplayPreferencesProvider>,
    )

    // The verb and market rows render; the empty rate row (no label/value, stray
    // info icon) must not.
    await waitFor(() => expect(screen.getByText("1.000000 ETH")).toBeInTheDocument())
    expect(screen.getByText("Pledge")).toBeInTheDocument()
    expect(screen.getByText("Market")).toBeInTheDocument()
    // Three info-row tooltips (amount + market + fee) — no orphan "rate" tooltip row.
    expect(screen.getAllByRole("button", { name: /more info/i })).toHaveLength(3)
  })
})
