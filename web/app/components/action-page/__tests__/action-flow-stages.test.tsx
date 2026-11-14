import { cleanup, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ActionConfigureStage } from "@/app/components/action-page/action-configure-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"

const preview: ActionPreviewUi = {
  allowed: true,
  amountLabel: "1,000 USDC",
  amountUsdLabel: "≈ $1,000.00",
  rateLabel: "Borrow APY",
  rateValue: "5.20%",
  marketLabel: "Market",
  marketValue: "USDC · Core",
  balanceLabel: "Available to Borrow",
  balanceValue: "$5,000.00",
  maxAmount: 5000,
  metrics: [{ id: "hf", label: "Health factor", value: "2.40 → 1.80" }],
  networkFeeLabel: "≈ $0.04",
  risk: null,
  blockedReason: null,
  validationErrors: [],
  warnings: [],
}

afterEach(() => {
  cleanup()
})

describe("action stage flow UI", () => {
  it("P1-18 uses FX and APY-specific help for swap and multiply rates", async () => {
    const user = userEvent.setup()
    const swapPreview = {
      ...preview,
      rateLabel: "Rate",
      rateValue: "1 USDC = 0.00031 WETH",
      marketValue: "Ethereum",
    }
    const { unmount } = render(
      <ActionConfigureStage
        stage="configure"
        verb="Swap"
        amount="1000"
        onAmountChange={() => undefined}
        preview={swapPreview}
        assetSymbol="USDC"
      />,
    )

    await user.click(screen.getByRole("button", { name: "More information about Rate" }))
    expect(screen.getByRole("tooltip")).toHaveTextContent("Estimated exchange rate for this swap")
    unmount()

    render(
      <ActionReviewStage
        title="Review multiply"
        preview={{
          ...preview,
          rateLabel: "",
          rateValue: "",
          marketBreakdown: {
            collateral: { symbol: "ETH", apy: "3.10%" },
            borrow: { symbol: "USDC", apy: "5.20%" },
          },
        }}
      />,
    )

    await user.click(screen.getByRole("button", { name: "More information about Collateral APY" }))
    expect(screen.getByRole("tooltip")).toHaveTextContent("Annualized yield earned by the collateral asset")
    await user.click(screen.getByRole("button", { name: "More information about Borrow APY" }))
    expect(screen.getByRole("tooltip")).toHaveTextContent("Annualized cost to borrow")
    expect(screen.queryByText(/market this action applies to/i)).not.toBeInTheDocument()
  })

  it("configure stage offers Review then review stage offers confirm verb", async () => {
    const user = userEvent.setup()
    const onPrimary = vi.fn()
    const onBack = vi.fn()

    const { rerender } = render(
      <ActionConfigureStage
        stage="configure"
        verb="Borrow"
        amount="1000"
        onAmountChange={() => undefined}
        preview={preview}
        assetSymbol="USDC"
        onPrimary={onPrimary}
        onSecondary={onBack}
        canGoBack
      />,
    )

    expect(screen.getByRole("button", { name: "Review" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Review" }))
    expect(onPrimary).toHaveBeenCalledTimes(1)

    rerender(
      <ActionReviewStage
        title="Review borrow"
        subtitle="Confirm the details below before signing."
        preview={preview}
        primaryLabel="Borrow"
        onPrimary={() => undefined}
        onSecondary={onBack}
      />,
    )

    expect(screen.getByTestId("action-review-stage")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Borrow" })).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Back" }))
    expect(onBack).toHaveBeenCalledTimes(1)
  })

  it("shows the risk message once on review when the Note warning duplicates it", () => {
    const message = "This leverage reduces your safety buffer."
    render(
      <ActionReviewStage
        title="Review multiply"
        preview={{
          ...preview,
          rateLabel: "",
          rateValue: "",
          risk: { level: "warning", title: "Review leverage carefully", message },
          warnings: [message],
        }}
        primaryLabel="Multiply"
        onPrimary={() => undefined}
        onSecondary={() => undefined}
      />,
    )

    // The risk banner shows the message; the duplicate "Note" row is suppressed.
    expect(screen.getByTestId("action-risk-banner")).toHaveTextContent(message)
    expect(screen.queryByText("Note")).not.toBeInTheDocument()
    expect(screen.getAllByText(message)).toHaveLength(1)
  })

  it("still shows a distinct Note warning alongside the risk banner", () => {
    render(
      <ActionReviewStage
        title="Review multiply"
        preview={{
          ...preview,
          risk: { level: "warning", title: "Review leverage carefully", message: "Watch your health factor." },
          warnings: ["Liquidity is thin in this market."],
        }}
        primaryLabel="Multiply"
        onPrimary={() => undefined}
        onSecondary={() => undefined}
      />,
    )

    expect(screen.getByTestId("action-risk-banner")).toHaveTextContent("Watch your health factor.")
    expect(screen.getByText("Note")).toBeInTheDocument()
    expect(screen.getByText("Liquidity is thin in this market.")).toBeInTheDocument()
  })

  it("requires explicit confirmation for a gated review", async () => {
    const user = userEvent.setup()
    const onPrimary = vi.fn()
    const onCheckedChange = vi.fn()
    render(
      <ActionReviewStage
        title="Review swap"
        preview={preview}
        primaryLabel="Swap"
        onPrimary={onPrimary}
        confirmationGate={{
          checked: false,
          onCheckedChange,
          label: "I understand this swap may result in a significant loss of value.",
        }}
      />,
    )

    expect(screen.getByRole("button", { name: "Swap" })).toBeDisabled()
    await user.click(screen.getByRole("checkbox"))
    expect(onCheckedChange).toHaveBeenCalledWith(true)
  })

  it("processing stage shows pending badge", () => {
    render(<ActionProcessingStage verb="Deposit" preview={preview} closeHref="/lend" />)
    expect(screen.getByTestId("action-processing-stage")).toBeInTheDocument()
    expect(screen.getByText("Pending")).toBeInTheDocument()
  })
})
