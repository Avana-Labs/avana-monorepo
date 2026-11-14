import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { SANDBOX_NETWORK_FEE_USD } from "@/app/lib/action-system/formatters"

// Capture the network fee the success stage hands to the receipt without depending
// on currency formatting.
vi.mock("@/app/components/action-page/transaction-receipt", () => ({
  TransactionReceipt: ({ data }: { data: { networkFeeUsd?: number | null } }) => (
    <div data-testid="net-fee">{String(data.networkFeeUsd)}</div>
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

afterEach(cleanup)

describe("ActionSuccessStage network fee", () => {
  it("charges the 15 bps platform fee on the amount for non-swap actions", () => {
    render(
      <ActionSuccessStage
        closeHref="/lend"
        success={{
          ...base,
          receiptContext: {
            verb: "Deposit",
            amountLabel: "1000 USDC",
            amountUsd: 1000,
            rateLabel: "Supply APY",
            rateValue: "5.00%",
            marketValue: "USDC · Core",
          },
        }}
      />,
    )
    expect(screen.getByTestId("net-fee").textContent).toBe("1.5")
  })

  it("keeps the real swap quote fee for swaps (not forced to $0.03)", () => {
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
            networkFeeUsd: 0.24,
          },
        }}
      />,
    )
    const fee = screen.getByTestId("net-fee").textContent
    expect(fee).toBe("0.24")
    expect(fee).not.toBe(String(SANDBOX_NETWORK_FEE_USD))
  })
})
