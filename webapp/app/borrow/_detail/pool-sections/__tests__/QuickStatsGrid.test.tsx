import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { TokenPricesContext } from "@/app/lib/prices/token-prices-context"
import { QuickStatsGrid } from "../QuickStatsGrid"

const currencyRef = { current: "USD" as string }

vi.mock("@/app/components/display-preferences", () => ({
  useOptionalLocaleDisplayPreferences: () => ({
    currency: currencyRef.current,
    language: "EN",
  }),
}))

afterEach(cleanup)

const detail = {
  quickStats: [
    { id: "totalSupplied", label: "Total Supplied", value: "$312.4M" },
    { id: "utilization", label: "Utilization", value: "62.1%" },
  ],
}

describe("QuickStatsGrid currency conversion", () => {
  it("renders Market overview money stats in USD by default", () => {
    currencyRef.current = "USD"
    const { getByText } = render(<QuickStatsGrid detail={detail} />)
    expect(getByText("$312.4M")).toBeInTheDocument()
    // Non-money stats are never touched.
    expect(getByText("62.1%")).toBeInTheDocument()
  })

  it("explains reserve metrics on hover", async () => {
    const { userEvent } = await import("@testing-library/user-event")
    const user = userEvent.setup()
    render(<QuickStatsGrid detail={detail} />)

    await user.hover(
      screen.getByRole("button", {
        name: "More information about Utilization",
      }),
    )
    expect(await screen.findByRole("tooltip")).toHaveTextContent(
      "Percentage of deposited assets currently being borrowed",
    )
  })

  it("re-denominates the money stat when the active currency is not USD", () => {
    currencyRef.current = "EUR"
    const { getByText, queryByText } = render(<QuickStatsGrid detail={detail} />)
    // $312.4M * 0.92 ≈ €287.4M — symbol and value both update.
    expect(getByText("€287.4M")).toBeInTheDocument()
    expect(queryByText("$312.4M")).toBeNull()
    // The percentage stat stays as-is (no mixed-currency artifact).
    expect(getByText("62.1%")).toBeInTheDocument()
  })

  it("updates the detail price when the shared live price context receives an oracle quote", () => {
    currencyRef.current = "USD"
    const detail = {
      hero: { symbol: "WBTC" },
      quickStats: [
        { id: "price", label: "Price", value: "$65,000.00" },
        { id: "utilization", label: "Utilization", value: "62.1%" },
      ],
    }
    const { rerender } = render(
      <TokenPricesContext.Provider value={{}}>
        <QuickStatsGrid detail={detail} />
      </TokenPricesContext.Provider>,
    )

    expect(screen.getByText("$65,000.00")).toBeInTheDocument()

    rerender(
      <TokenPricesContext.Provider value={{ wbtc: 84392.11 }}>
        <QuickStatsGrid detail={detail} />
      </TokenPricesContext.Provider>,
    )

    expect(screen.getByText("$84,392.11")).toBeInTheDocument()
    expect(screen.getByText("62.1%")).toBeInTheDocument()
  })

  it("uses an explicit collateral symbol for pair-market detail prices", () => {
    currencyRef.current = "USD"
    const detail = {
      hero: { visuals: [{ symbol: "WBTC" }, { symbol: "WETH" }] },
      quickStats: [{ id: "price", label: "Price", value: "$65,000.00" }],
    }

    render(
      <TokenPricesContext.Provider value={{ wbtc: 84392.11 }}>
        <QuickStatsGrid detail={detail} priceSymbol={detail.hero.visuals[0].symbol} />
      </TokenPricesContext.Provider>,
    )

    expect(screen.getByText("$84,392.11")).toBeInTheDocument()
  })

  it("updates a pool pair rate from both live token quotes", () => {
    currencyRef.current = "USD"
    const detail = {
      hero: { visuals: [{ symbol: "WBTC" }, { symbol: "WETH" }] },
      quickStats: [{ id: "price", label: "Price", value: "33.61 WETH" }],
    }
    const { rerender } = render(
      <TokenPricesContext.Provider value={{}}>
        <QuickStatsGrid detail={detail} pricePair={["WBTC", "WETH"]} />
      </TokenPricesContext.Provider>,
    )

    expect(screen.getByText("33.61 WETH")).toBeInTheDocument()

    rerender(
      <TokenPricesContext.Provider value={{ wbtc: 84392.11, weth: 2500 }}>
        <QuickStatsGrid detail={detail} pricePair={["WBTC", "WETH"]} />
      </TokenPricesContext.Provider>,
    )

    expect(screen.getByText("33.76 WETH")).toBeInTheDocument()
  })
})
