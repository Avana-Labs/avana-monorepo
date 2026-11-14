import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { buildPositionContext, type PositionSnapshotInput } from "@/convex/lib/askAI/positionContext"
import { buildReturnsRun, buildRiskRun, buildStressRun } from "@/convex/lib/askAI/modeRun"
import { AskAiRunCards } from "../components/ask-ai-run-cards"

afterEach(cleanup)

const base: PositionSnapshotInput = {
  positionId: "pos_1",
  product: "borrow",
  collateralValueUsd: 10_000,
  debtValueUsd: 5_000, // HF = 10000*0.65/5000 = 1.30 (risky, triggers actions)
  maxLtvPct: 55,
  liquidationThresholdPct: 65,
  borrowApyPct: 5,
  lpFeeApr7dPct: 18.25,
  constituents: [
    { symbol: "ETH", weight: 0.5, feeApr7dPct: 20, inRange: true },
    { symbol: "USDC", weight: 0.5, feeApr7dPct: 4, inRange: true },
  ],
  lastUpdatedAt: 1_700_000_000_000,
}
const ctx = buildPositionContext(base, 1_700_000_100_000)
const opts = { queryText: "am I safe?", provenance: "sandbox" }

describe("AskAiRunCards", () => {
  it("renders a risk run with native cards, the health factor, and defensive actions", () => {
    render(<AskAiRunCards run={buildRiskRun(ctx, opts)} />)
    expect(screen.getByTestId("ask-ai-run-cards")).toHaveAttribute("data-mode", "risk")
    expect(screen.getByText("Position risk")).toBeInTheDocument()
    expect(screen.getByText("Liquidation buffer")).toBeInTheDocument()
    expect(screen.getByText("Collateral breakdown")).toBeInTheDocument()
    expect(screen.getByTestId("action-health-factor-card")).toBeInTheDocument() // native HF bar
    expect(screen.getByText("Suggested actions")).toBeInTheDocument()
    expect(screen.getByText(/Repay \$/)).toBeInTheDocument()
  })

  it("renders a returns run with net carry and ranked comparable LPs", () => {
    const run = buildReturnsRun(ctx, {
      ...opts,
      comparableCandidates: [
        { id: "a", label: "ETH / USDC 0.05%", feeApr7dPct: 13, borrowApyPct: 5 },
        { id: "b", label: "ETH / USDC 0.3%", feeApr7dPct: 20, borrowApyPct: 5 },
      ],
    })
    render(<AskAiRunCards run={run} />)
    expect(screen.getByText("Net carry")).toBeInTheDocument()
    expect(screen.getByText("Comparable LPs")).toBeInTheDocument()
    expect(screen.getByText("ETH / USDC 0.3%")).toBeInTheDocument()
  })

  it("renders stress tiles and flags liquidation on the deepest shock", () => {
    render(<AskAiRunCards run={buildStressRun(ctx, opts)} />)
    expect(screen.getByText("Price-shock scenarios")).toBeInTheDocument()
    expect(screen.getAllByText(/Liquidated/).length).toBeGreaterThan(0)
  })

  it("omits fee and carry cards when their inputs are unavailable", () => {
    const noFee = buildPositionContext(
      { ...base, lpFeeApr7dPct: undefined, borrowApyPct: undefined, constituents: [{ symbol: "ETH", weight: 1 }] },
      1,
    )
    render(<AskAiRunCards run={buildReturnsRun(noFee, opts)} />)
    expect(screen.queryByText("Net carry")).not.toBeInTheDocument()
    expect(screen.queryByText("Fees vs interest per day")).not.toBeInTheDocument()
  })

  it("omits an empty collateral table", () => {
    const noLegs = buildPositionContext({ ...base, constituents: [] }, 1)
    render(<AskAiRunCards run={buildRiskRun(noLegs, opts)} />)
    expect(screen.queryByText("Collateral breakdown")).not.toBeInTheDocument()
  })
})
