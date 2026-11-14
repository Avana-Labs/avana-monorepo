import { describe, expect, it } from "vitest"
import { interpolateScrubSample, scrubRatioFromPointer, type ScrubPlotPoint } from "../hero-scrub"

const points: ScrubPlotPoint[] = [
  { time: 1, value: 100, label: "10:00", x: 0, y: 200 },
  { time: 2, value: 200, label: "11:00", x: 100, y: 100 },
  { time: 3, value: 150, label: "12:00", x: 200, y: 150 },
]

describe("scrubRatioFromPointer", () => {
  it("maps pointer X into a clamped 0–1 plot ratio", () => {
    expect(scrubRatioFromPointer(50, 0, 0, 200)).toBe(0.25)
    expect(scrubRatioFromPointer(-10, 0, 0, 200)).toBe(0)
    expect(scrubRatioFromPointer(400, 0, 0, 200)).toBe(1)
    expect(scrubRatioFromPointer(120, 0, 20, 200)).toBe(0.5)
  })
})

describe("interpolateScrubSample", () => {
  it("returns null for an empty series", () => {
    expect(interpolateScrubSample([], 0.5)).toBeNull()
  })

  it("returns the single point for a one-sample series", () => {
    const sample = interpolateScrubSample([points[0]!], 0.8)
    expect(sample).toEqual({
      x: 0,
      y: 200,
      value: 100,
      label: "10:00",
      time: 1,
      indexFloor: 0,
      progress: 0,
    })
  })

  it("interpolates mid-segment instead of snapping to the nearest index", () => {
    const sample = interpolateScrubSample(points, 0.25)
    expect(sample).not.toBeNull()
    expect(sample!.indexFloor).toBe(0)
    expect(sample!.progress).toBeCloseTo(0.5)
    expect(sample!.value).toBeCloseTo(150)
    expect(sample!.x).toBeCloseTo(50)
    expect(sample!.y).toBeCloseTo(150)
    // At exactly 50% progress we prefer the right-side label.
    expect(sample!.label).toBe("11:00")
  })

  it("uses the right-side label once past the segment midpoint", () => {
    const sample = interpolateScrubSample(points, 0.3)
    expect(sample!.indexFloor).toBe(0)
    expect(sample!.progress).toBeCloseTo(0.6)
    expect(sample!.label).toBe("11:00")
  })

  it("clamps to the ends of the series", () => {
    const start = interpolateScrubSample(points, -1)!
    const end = interpolateScrubSample(points, 2)!
    expect(start.value).toBe(100)
    expect(start.x).toBe(0)
    expect(end.value).toBe(150)
    expect(end.x).toBe(200)
    expect(end.indexFloor).toBe(1)
  })
  it("keeps the dot under the pointer when points are unevenly spaced in time", () => {
    // Four daily points, then a long gap: the last point sits far to the right on a time axis.
    const uneven: ScrubPlotPoint[] = [
      { time: 0, value: 10, label: "d0", x: 0, y: 100 },
      { time: 1, value: 20, label: "d1", x: 10, y: 90 },
      { time: 2, value: 30, label: "d2", x: 20, y: 80 },
      { time: 3, value: 40, label: "d3", x: 30, y: 70 },
      { time: 10, value: 110, label: "d10", x: 100, y: 0 },
    ]
    // Pointer at 50% of the plot = x 50, inside the d3 → d10 gap.
    const sample = interpolateScrubSample(uneven, 0.5)!
    expect(sample.x).toBeCloseTo(50)
    expect(sample.indexFloor).toBe(3)
    expect(sample.progress).toBeCloseTo(20 / 70)
    expect(sample.value).toBeCloseTo(40 + 70 * (20 / 70))
    // Pointer at 15% = x 15, halfway between d1 and d2 (index mapping would have chosen d2 → d3).
    const early = interpolateScrubSample(uneven, 0.15)!
    expect(early.x).toBeCloseTo(15)
    expect(early.indexFloor).toBe(1)
    expect(early.value).toBeCloseTo(25)
  })
})
