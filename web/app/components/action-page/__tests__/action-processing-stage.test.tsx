import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"

const preview: ActionPreviewUi = {
  allowed: true,
  amountLabel: "1.5 WETH",
  amountUsdLabel: "≈ $4,500.00",
  rateLabel: "Net APY",
  rateValue: "8.10%",
  marketLabel: "Market",
  marketValue: "WETH · Core",
  balanceLabel: "Multiplier",
  balanceValue: "2.50x",
  maxAmount: 3,
  metrics: [],
  networkFeeLabel: "≈ $0.04",
  risk: null,
  blockedReason: null,
  validationErrors: [],
  warnings: [],
  executionSteps: [
    { id: "supply", label: "Supply initial collateral" },
    { id: "borrow", label: "Loop 1: Borrow" },
  ],
}

describe("ActionProcessingStage", () => {
  it("renders pending hero with amount context", async () => {
    render(<ActionProcessingStage verb="Deposit" preview={preview} closeHref="/lend" />)

    expect(screen.getByTestId("action-processing-stage")).toBeInTheDocument()
    expect(screen.getByText("Pending")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Depositing WETH" })).toBeInTheDocument()
    expect(screen.getByTestId("processing-narration")).toBeInTheDocument()
    expect(screen.getByText("Connecting to Aave v4")).toBeInTheDocument()
    // The redundant executionSteps list is intentionally NOT rendered — the narration
    // animation above already conveys the per-verb steps (was duplicated on every action).
    expect(screen.queryByRole("list", { name: "Execution steps" })).not.toBeInTheDocument()
    expect(screen.queryByText("Loop 1: Borrow")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Close" })).toHaveAttribute("href", "/lend")
  })

  it("uses the correct verb inflection for remove flows", () => {
    render(<ActionProcessingStage verb="Remove" preview={{ ...preview, amountLabel: "25%" }} closeHref="/dashboard" />)

    expect(screen.getByRole("heading", { name: "Removing 25%" })).toBeInTheDocument()
  })
})
