import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
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
  balanceLabel: "Balance",
  balanceValue: "1.28",
}

describe("ActionAmountCard", () => {
  it("does not prefill the amount input", () => {
    render(<ActionAmountCard {...baseProps} />)
    const input = screen.getByLabelText("Deposit amount") as HTMLInputElement
    expect(input.value).toBe("")
  })

  it("renders a non-interactive pill (no dropdown) when not switchable", () => {
    const { container } = render(<ActionAmountCard {...baseProps} />)
    expect(screen.queryByRole("listbox")).toBeNull()
    // No chevron / haspopup affordance when there's nothing to switch to.
    expect(container.querySelector('[aria-haspopup="listbox"]')).toBeNull()
  })

  it("keeps the asset chip labeled when switching is disabled in embedded layouts", () => {
    const { container } = render(
      <ActionAmountCard {...baseProps} assetLabel="AAVE" assetSymbol="AAVE" borrowSymbol="GHO" variant="raised" />,
    )

    expect(screen.queryByRole("listbox")).toBeNull()
    expect(screen.getByText("AAVE")).toBeInTheDocument()
    expect(container.querySelector('[aria-haspopup="listbox"]')).toBeNull()
  })

  it("opens a switcher and changes asset when options are provided", () => {
    const onAssetSelect = vi.fn()
    render(
      <ActionAmountCard
        {...baseProps}
        selectedAssetId="eth"
        onAssetSelect={onAssetSelect}
        assetOptions={[
          { id: "eth", label: "Ethereum", symbol: "ETH" },
          { id: "usdc", label: "USD Coin", symbol: "USDC" },
          { id: "wbtc", label: "Wrapped BTC", symbol: "WBTC" },
        ]}
      />,
    )

    const trigger = screen.getByRole("button", { name: /change asset/i })
    expect(trigger.getAttribute("aria-haspopup")).toBe("listbox")
    fireEvent.click(trigger)

    expect(screen.getByRole("listbox")).toBeTruthy()
    fireEvent.click(screen.getByRole("option", { name: /USD Coin/i }))
    expect(onAssetSelect).toHaveBeenCalledWith("usdc")
    // Menu closes after selection.
    expect(screen.queryByRole("listbox")).toBeNull()
  })

  it("renders a fixed unit pill when a unit label is provided", () => {
    render(<ActionAmountCard {...baseProps} unitLabel="%" />)

    expect(screen.getByText("%")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /change asset/i })).toBeNull()
  })

  it("shows the balance as a clickable shortcut that fills the balance", () => {
    const onMax = vi.fn()
    render(<ActionAmountCard {...baseProps} balanceLabel="Balance" balanceValue="1.28 ETH" onMax={onMax} />)

    // The ticker is dropped from the displayed value (shown in the picker instead).
    expect(screen.getByText("1.28")).toBeInTheDocument()
    const balanceButton = screen.getByRole("button", { name: /Balance: 1\.28/ })
    fireEvent.click(balanceButton)
    expect(onMax).toHaveBeenCalledTimes(1)
  })

  it("renders the balance as static text (not clickable) in read-only review mode", () => {
    render(<ActionAmountCard {...baseProps} balanceLabel="Balance" balanceValue="1.28 ETH" onMax={() => {}} readOnly />)

    expect(screen.getByText("1.28")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Balance: 1\.28/ })).toBeNull()
  })
})
