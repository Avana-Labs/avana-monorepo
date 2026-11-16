import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { mapBorrowSuccessToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"

// Capture the platform fee the success stage hands to the receipt without depending
// on currency formatting.
vi.mock("@/app/components/action-page/transaction-receipt", () => ({
  TransactionReceipt: ({ data }: { data: { platformFeeUsd?: number | null } }) => (
    <div data-testid="platform-fee">{String(data.platformFeeUsd)}</div>
  ),
}))

import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"

const base: ActionSuccessUi = {
  title: "Deposit successful",
  description: "processed",
  receiptHash: "sim-xyz",
  metrics: [],
  primaryCtaLabel: "View",
  primaryCtaHref: "/lend",
  secondaryCtaLabel: "Done",
}

const preview = {
  quoteId: "q",
  amountLabel: "1000 USDC",
  amountUsd: 1000,
  rateLabel: "Supply APY",
  rateValue: "5.00%",
  marketValue: "USDC · Core",
}

afterEach(cleanup)

describe("ActionSuccessStage platform fee", () => {
  it("shows the Q-409 front-end fee of the action (10 bps by default) on the receipt", () => {
    const success = mapBorrowSuccessToActionUi({
      ...base,
      href: "/lend",
      preview,
      verb: "Deposit",
      feeAction: "supply",
    })
    expect(success.receiptContext?.platformFeeUsd).toBe(1)
    render(<ActionSuccessStage closeHref="/lend" success={{ ...success, receiptHash: "sim-xyz" }} />)
    expect(screen.getByTestId("platform-fee").textContent).toBe("1")
  })

  it("charges no front-end fee for claim, which is not a Q-409 action", () => {
    const success = mapBorrowSuccessToActionUi({ ...base, href: "/borrow", preview, verb: "Claim", feeAction: null })
    expect(success.receiptContext?.platformFeeUsd).toBe(0)
  })

  it("keeps the fee a swap receipt carries", () => {
    render(
      <ActionSuccessStage
        closeHref="/swap"
        success={{
          ...base,
          title: "Swap successful.",
          receiptContext: {
            verb: "Sold",
            amountLabel: "1 WETH",
            rateLabel: "Received",
            rateValue: "1900 USDC",
            marketValue: "Uniswap",
            platformFeeUsd: 0.24,
          },
        }}
      />,
    )
    expect(screen.getByTestId("platform-fee").textContent).toBe("0.24")
  })
})
