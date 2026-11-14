import { describe, expect, it } from "vitest"
import { blendEquityWeightedNetApyPct, resolveDashboardNetApyPct } from "@/app/dashboard/portfolio-headline-metrics"

describe("blendEquityWeightedNetApyPct", () => {
  it("equity-weights product Net APYs (not a flat average)", () => {
    const apy = blendEquityWeightedNetApyPct([
      { equityUsd: 1_000, netApyPct: 10 },
      { equityUsd: 3_000, netApyPct: 2 },
    ])
    // (10*1000 + 2*3000) / 4000 = 4 — not (10+2)/2 = 6
    expect(apy).toBeCloseTo(4, 6)
  })

  it("skips non-positive equity so underwater legs do not invert the blend", () => {
    const apy = blendEquityWeightedNetApyPct([
      { equityUsd: 2_000, netApyPct: 5 },
      { equityUsd: -500, netApyPct: 100 },
      { equityUsd: 0, netApyPct: 50 },
    ])
    expect(apy).toBeCloseTo(5, 6)
  })

  it("returns 0 when there are no productive legs", () => {
    expect(blendEquityWeightedNetApyPct([])).toBe(0)
    expect(blendEquityWeightedNetApyPct([{ equityUsd: 0, netApyPct: 8 }])).toBe(0)
  })
})

describe("resolveDashboardNetApyPct", () => {
  it("prefers a non-zero client blend over Convex", () => {
    expect(resolveDashboardNetApyPct(4.2, 0)).toBeCloseTo(4.2, 6)
  })

  it("keeps genuine client zero even when Convex has a stale figure", () => {
    expect(resolveDashboardNetApyPct(0, 3.1)).toBe(0)
  })

  it("falls back to Convex when client blend is unavailable", () => {
    expect(resolveDashboardNetApyPct(null, 3.1)).toBeCloseTo(3.1, 6)
    expect(resolveDashboardNetApyPct(null, undefined)).toBe(0)
  })
})
