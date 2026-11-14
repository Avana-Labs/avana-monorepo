import { render } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { LendHero } from "../lend-hero"
import { MARKETS } from "../data"

vi.mock("@/app/components/display-preferences", () => ({
  useAmountDisplayPreferences: () => ({ showDollarAmounts: true }),
  useOptionalLocaleDisplayPreferences: () => ({ currency: "USD", language: "EN" }),
}))

describe("LendHero", () => {
  it("renders lending metrics", () => {
    const { getByText } = render(<LendHero markets={MARKETS} />)

    expect(getByText("Lend TVL")).toBeInTheDocument()
    expect(getByText("$31.4M")).toBeInTheDocument()
    expect(getByText("Testnet")).toBeInTheDocument()
    expect(getByText("Average APY")).toBeInTheDocument()
    expect(getByText("8.42%")).toBeInTheDocument()
    expect(getByText("Avg Utilization")).toBeInTheDocument()
    expect(getByText("67.61%")).toBeInTheDocument()
  })

  it("parses mixed TVL suffixes correctly instead of treating K-values as millions", () => {
    const { getByText } = render(
      <LendHero
        markets={[
          {
            symbol: "EURC",
            name: "Euro Coin",
            apy: 1,
            apyChange24h: 0,
            tvl: "$98.6K",
            utilization: 20,
            type: "low",
            protocol: "EURC",
            color: "",
            bg: "",
            soon: false,
            event: null,
          },
          {
            symbol: "ETH",
            name: "Ethereum",
            apy: 4,
            apyChange24h: 0,
            tvl: "$1.0M",
            utilization: 50,
            type: "medium",
            protocol: "ETH",
            color: "",
            bg: "",
            soon: false,
            event: null,
          },
        ]}
      />,
    )

    expect(getByText("$1.1M")).toBeInTheDocument()
    expect(getByText("3.73%")).toBeInTheDocument()
  })
})
