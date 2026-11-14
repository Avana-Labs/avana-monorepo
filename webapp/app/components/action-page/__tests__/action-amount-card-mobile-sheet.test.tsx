import { cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

// Force the mobile branch so the inline selector renders as a bottom-sheet.
vi.mock("@/app/lib/use-media-query", () => ({
  useMediaQuery: () => false,
}))

import { ActionAmountCard } from "@/app/components/action-page/action-amount-card"

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const baseProps = {
  label: "Deposit",
  amount: "",
  onAmountChange: () => {},
  approxUsdLabel: "≈ $0.00",
  assetLabel: "ETH",
  assetSymbol: "ETH",
}

describe("ActionAmountCard mobile selector", () => {
  it("opens the token/market selector as a bottom-sheet dialog on mobile", () => {
    const onAssetSelect = vi.fn()
    render(
      <ActionAmountCard
        {...baseProps}
        selectedAssetId="eth"
        onAssetSelect={onAssetSelect}
        assetOptions={[
          { id: "eth", label: "Ethereum", symbol: "ETH" },
          { id: "usdc", label: "USD Coin", symbol: "USDC" },
        ]}
      />,
    )

    // No anchored popover is present before opening.
    expect(screen.queryByRole("listbox")).toBeNull()

    fireEvent.click(screen.getByRole("button", { name: /change asset/i }))

    // The overlay is a Radix Dialog (same primitive as the search/token sheets),
    // and it hosts the option list.
    const dialog = screen.getByRole("dialog")
    expect(dialog).toBeTruthy()
    const listbox = within(dialog).getByRole("listbox", { name: /select asset/i })
    expect(listbox).toBeTruthy()

    fireEvent.click(within(listbox).getByRole("option", { name: /USD Coin/i }))
    expect(onAssetSelect).toHaveBeenCalledWith("usdc")
  })
})
