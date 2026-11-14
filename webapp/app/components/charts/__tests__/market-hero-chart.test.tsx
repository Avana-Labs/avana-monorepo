import { cleanup, render } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MarketHeroChart } from "../market-hero-chart"
import { setActiveCurrency } from "@/app/lib/currency/active-rate"
import { formatChartValue } from "../format"
import type { ChartFeed } from "../types"

const currencyRef = { current: "USD" as string }

vi.mock("@/app/components/display-preferences", () => ({
  useOptionalLocaleDisplayPreferences: () => ({ currency: currencyRef.current, language: "EN" }),
}))

// The area chart / range selector are SVG-heavy and irrelevant to the headline
// conversion under test; stub them so the test isolates the resting headline.
vi.mock("../hero-area-chart", () => ({ HeroAreaChart: () => null }))
vi.mock("../chart-range-selector", () => ({ ChartRangeSelector: () => null }))
// Springs would leave intermediate formatted values in the DOM; snap for assertions.
vi.mock("../hero-animated-number", () => ({
  HeroAnimatedNumber: ({ value, format }: { value: number; format: (value: number) => string }) => (
    <span>{format(value)}</span>
  ),
}))

afterEach(cleanup)

const tip = 312_400_000

const feed: ChartFeed = {
  headlineValue: "$312.4M",
  headlineDelta: "$1.0M (0.32%)",
  deltaTone: "positive",
  rangeData: {
    "1D": [{ time: 0, value: tip, label: "" }],
    "1W": [{ time: 0, value: tip, label: "" }],
    "1M": [{ time: 0, value: tip, label: "" }],
    "3M": [{ time: 0, value: tip, label: "" }],
    "1Y": [{ time: 0, value: tip, label: "" }],
    All: [{ time: 0, value: tip, label: "" }],
  },
  valueFormat: "usdCompact",
}

describe("MarketHeroChart headline currency conversion", () => {
  it("shows the tip value formatted for the active currency in USD", () => {
    currencyRef.current = "USD"
    setActiveCurrency("USD")
    const { getByText } = render(<MarketHeroChart feed={feed} />)
    expect(getByText(formatChartValue("usdCompact", tip))).toBeInTheDocument()
  })

  it("re-denominates the resting headline so it no longer mixes currencies with the delta", () => {
    currencyRef.current = "EUR"
    setActiveCurrency("EUR")
    const { getByText, queryByText } = render(<MarketHeroChart feed={feed} />)
    expect(getByText(formatChartValue("usdCompact", tip))).toBeInTheDocument()
    expect(queryByText("$312.4M")).toBeNull()
    expect(queryByText("$312.40M")).toBeNull()
    setActiveCurrency("USD")
  })
})
