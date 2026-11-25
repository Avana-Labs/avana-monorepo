import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SwapPageClient } from "@/app/swap/swap-page-client"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { TransactAccessContext } from "@/app/lib/transact-access"

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

vi.mock("@/app/lib/currency/use-currency", () => ({
  useCurrency: () => ({ exact: (value: number) => `$${value.toFixed(2)}` }),
}))

afterEach(() => cleanup())

function renderSwap() {
  return render(
    <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
      <SwapPageClient initialFrom="eth" initialTo="usdc" />
    </AvanaSessionsProvider>,
  )
}

describe("SwapPageClient", () => {
  // Prod 2026-09-23: a guest on /swap saw only a disabled "Select assets" button.
  it("offers a guest Get Started instead of a disabled button", () => {
    render(
      <TransactAccessContext.Provider value="guest">
        <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
          <SwapPageClient />
        </AvanaSessionsProvider>
      </TransactAccessContext.Provider>,
    )
    expect(screen.getByRole("button", { name: "Get Started" })).toBeEnabled()
  })

  it("starts Sell on ETH like the homepage, with Buy empty, on the standalone swap route", () => {
    render(
      <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
        <SwapPageClient />
      </AvanaSessionsProvider>,
    )

    expect(screen.getByRole("button", { name: /^Sell asset/ })).toHaveTextContent("ETH")
    expect(screen.getByRole("button", { name: /^Buy asset/ })).toHaveTextContent("Select asset")
    expect(screen.getByRole("button", { name: "Select assets" })).toBeDisabled()
    expect(screen.getByText(/Step 1 of 3/)).toBeInTheDocument()
  })

  it("renders the canonical swap page", () => {
    renderSwap()

    expect(screen.getByRole("heading", { name: "Swap" })).toBeInTheDocument()
    expect(screen.getByLabelText("Sell")).toBeInTheDocument()
    expect(screen.getByLabelText("Buy")).toBeInTheDocument()
  })

  it("searches supported assets in the receive picker", async () => {
    renderSwap()

    fireEvent.click(screen.getByRole("button", { name: /^Buy asset/ }))
    fireEvent.change(await screen.findByLabelText("Find an asset"), { target: { value: "chain" } })
    fireEvent.click(screen.getByText("ChainLink Token").closest("button")!)

    expect(screen.getByRole("button", { name: /^Buy asset/ })).toHaveTextContent("LINK")
  })
})
