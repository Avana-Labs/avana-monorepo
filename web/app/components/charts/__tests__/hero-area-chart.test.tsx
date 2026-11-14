import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { buildHeroAreaGeometry, HeroAreaChart } from "../hero-area-chart"

const points = [
  { time: 1, value: 100, label: "10:00" },
  { time: 2, value: 108, label: "11:00" },
  { time: 3, value: 104, label: "12:00" },
]

describe("HeroAreaChart", () => {
  it("builds a smooth closed area without Recharts", () => {
    const geometry = buildHeroAreaGeometry(points, 800, 240, "1D", (value) => `axis:${Math.round(value)}`)
    expect(geometry.points).toHaveLength(3)
    expect(geometry.linePath).toContain(" C ")
    expect(geometry.areaPath).toMatch(/ Z$/)
    expect(geometry.axisTicks.map((tick) => tick.label)).toEqual([
      "axis:112",
      "axis:109",
      "axis:106",
      "axis:102",
      "axis:99",
      "axis:96",
    ])
    expect(geometry.xAxisTicks.length).toBeGreaterThan(0)
  })

  it("keeps one x-axis label per unique series label", () => {
    const series = [
      { time: 0, value: 100, label: "6:00 AM" },
      { time: 1, value: 101, label: "6:00 AM" },
      { time: 2, value: 102, label: "9:00 AM" },
      { time: 3, value: 103, label: "12:00 PM" },
      { time: 4, value: 104, label: "3:00 PM" },
      { time: 5, value: 105, label: "3:00 PM" },
      { time: 6, value: 106, label: "6:00 PM" },
      { time: 7, value: 107, label: "9:00 PM" },
      { time: 8, value: 108, label: "Now" },
    ]
    const geometry = buildHeroAreaGeometry(series, 900, 310, "1D")
    expect(geometry.xAxisTicks.map((tick) => tick.label)).toEqual([
      "6:00 AM",
      "9:00 AM",
      "12:00 PM",
      "3:00 PM",
      "6:00 PM",
      "9:00 PM",
      "Now",
    ])
    expect(geometry.axisTicks).toHaveLength(6)
    expect(geometry.points[0]?.x).toBe(0)
    expect(geometry.xAxisTicks.at(-1)?.x).toBe(geometry.points.at(-1)?.x)
  })

  it("subsamples dense day labels so 1M stays readable", () => {
    const series = Array.from({ length: 30 }, (_, index) => ({
      time: index,
      value: 100 + index,
      label: `Jun ${index + 1}`,
    }))
    const geometry = buildHeroAreaGeometry(series, 900, 310, "1M")
    expect(geometry.xAxisTicks.length).toBeGreaterThanOrEqual(3)
    expect(geometry.xAxisTicks.length).toBeLessThanOrEqual(6)
    expect(geometry.xAxisTicks[0]?.label).toBe("Jun 1")
    expect(geometry.xAxisTicks.at(-1)?.label).toBe("Jun 30")
  })

  it("publishes continuous scrub samples and clears on pointer exit", () => {
    const onScrubChange = vi.fn()
    const onActiveIndexChange = vi.fn()
    render(
      <HeroAreaChart
        data={points}
        activeRange="1D"
        formatValue={(value) => `value:${value.toFixed(1)}`}
        formatYAxis={(value) => `axis:${Math.round(value)}`}
        onScrubChange={onScrubChange}
        onActiveIndexChange={onActiveIndexChange}
        showTooltip
      />,
    )
    const chart = screen.getByTestId("hero-area-chart")
    vi.spyOn(chart, "getBoundingClientRect").mockReturnValue({
      x: 0,
      y: 0,
      left: 0,
      top: 0,
      right: 300,
      bottom: 240,
      width: 300,
      height: 240,
      toJSON: () => ({}),
    })

    // Default geometry width is 1000 (pre-ResizeObserver); right gutter 58.
    // plotWidth = 942. For ratio 0.25 → svgX = 0.25 * 942 = 235.5
    // shell CSS width is mocked at 300 → clientX = 235.5 * (300/1000) = 70.65
    fireEvent.pointerMove(chart, { clientX: 70.65 })

    expect(onScrubChange).toHaveBeenCalled()
    const sample = onScrubChange.mock.calls.at(-1)?.[0] as {
      indexFloor: number
      value: number
      progress: number
    }
    expect(sample.indexFloor).toBe(0)
    expect(sample.progress).toBeCloseTo(0.5, 1)
    expect(sample.value).toBeCloseTo(104, 0)
    expect(onActiveIndexChange).toHaveBeenLastCalledWith(0)
    expect(screen.getByTestId("hero-scrub-y-pill")).toBeInTheDocument()

    fireEvent.pointerLeave(chart)
    expect(onScrubChange).toHaveBeenLastCalledWith(null)
    expect(onActiveIndexChange).toHaveBeenLastCalledWith(null)
    expect(screen.queryByTestId("hero-scrub-y-pill")).not.toBeInTheDocument()
  })
})
