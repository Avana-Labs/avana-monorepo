import type { ReactNode } from "react"
import { cleanup, render } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import type { ChartFeed } from "../types"

// Render every lazy chart in its loading state: that frame must already hold the chart's height.
vi.mock("next/dynamic", () => ({
  default: (_loader: unknown, options: { loading: () => ReactNode }) =>
    function Loading() {
      return <>{options.loading()}</>
    },
}))
vi.mock("@/app/components/display-preferences", () => ({
  useOptionalLocaleDisplayPreferences: () => ({ currency: "USD", language: "EN" }),
}))
vi.mock("../chart-range-selector", () => ({ ChartRangeSelector: () => null }))

import { MarketHeroChart } from "../market-hero-chart"

afterEach(cleanup)

const point = [{ time: 0, value: 1, label: "" }]
const feed: ChartFeed = {
  headlineValue: "$1",
  headlineDelta: "$0 (0%)",
  deltaTone: "positive",
  rangeData: { "1D": point, "1W": point, "1M": point, "3M": point, "1Y": point, All: point },
} as ChartFeed

it("reserves a custom chart height while the chart chunk loads, so the page does not jump", () => {
  const { container } = render(<MarketHeroChart feed={feed} height={310} />)
  const slot = container.querySelector<HTMLElement>("[data-hero-chart-slot]")
  expect(slot?.style.minHeight).toBe("310px")
})
