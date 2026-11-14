import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import {
  borrowAprAtUtilization,
  borrowDeltaUsdToUtilization,
  buildBorrowInterestRateCurve,
  buildPercentAxisTicks,
  niceCeil,
  probeInterestRateModel,
  resolveMarketLiquidityUsd,
} from "@/app/lib/borrow-detail/interest-rate-curve"

describe("interest-rate-curve", () => {
  it("niceCeil uses 1-2-5 magnitude steps", () => {
    expect(niceCeil(10)).toBe(10)
    expect(niceCeil(11)).toBe(20)
    expect(niceCeil(51)).toBe(100)
    expect(niceCeil(3.2)).toBe(5)
  })

  it("buildPercentAxisTicks scales past the old hardcoded 0–10% axis", () => {
    const ticks = buildPercentAxisTicks(51)
    expect(ticks[0]).toBe(0)
    expect(ticks.at(-1)).toBe(100)
    expect(ticks.at(-1)!).toBeGreaterThan(10)
  })

  it("kinked curve reaches slope-above-optimal at 100% util", () => {
    const curve = buildBorrowInterestRateCurve(70, 4, {
      optimalUtilizationPct: 80,
      slopeBelowOptimalPct: 4,
      slopeAboveOptimalPct: 60,
      baseBorrowRatePct: 0.5,
    })
    const atOptimal = curve.points.find((point) => point.utilization === 80)!
    const atFull = curve.points.find((point) => point.utilization === 100)!
    expect(atOptimal.apr).toBeCloseTo(4.5, 5)
    expect(atFull.apr).toBeCloseTo(64.5, 5)
    expect(curve.maxApr).toBeGreaterThanOrEqual(64.5)
    expect(curve.yTicks.at(-1)).toBe(curve.maxApr)
  })

  // C1: the curve must be anchored to the rate actually paid — the curve value AT the
  // current utilization has to equal the displayed/paid APR, regardless of the (slug-hashed)
  // base-rate param. Otherwise the "Current" marker points at a curve value that is NOT the
  // headline APR (the marker-vs-headline mismatch this test guards against).
  const irm = {
    optimalUtilizationPct: 80,
    slopeBelowOptimalPct: 4,
    slopeAboveOptimalPct: 60,
    baseBorrowRatePct: 0.5,
  }

  it("anchors the curve so curve(currentUtilization) === paid APR even when base param disagrees", () => {
    // Unanchored, apr(50) would be 0.5 + 4·(50/80) = 3.0 — but the engine charges 8.0.
    const paidApr = 8
    const curve = buildBorrowInterestRateCurve(50, paidApr, irm)
    const atCurrent = curve.points.find((point) => point.utilization === 50)!
    expect(atCurrent.apr).toBeCloseTo(paidApr, 6)
    expect(borrowAprAtUtilization(50, irm, { utilization: 50, apr: paidApr })).toBeCloseTo(paidApr, 6)
    // The kinked shape is preserved (slopes intact) around the anchor.
    expect(curve.points.find((p) => p.utilization === 100)!.apr).toBeGreaterThan(paidApr)
  })

  it("holds the anchor for a flat, utilization-independent paid APR at any utilization", () => {
    for (const [util, paidApr] of [
      [20, 6.2],
      [64, 8],
      [95, 12.5],
    ] as const) {
      const curve = buildBorrowInterestRateCurve(util, paidApr, irm)
      expect(curve.points.find((p) => p.utilization === util)!.apr).toBeCloseTo(paidApr, 6)
    }
  })

  it("exposes the anchored base APR (curve value at 0% util) for the displayed base-rate row", () => {
    const paidApr = 8
    const curve = buildBorrowInterestRateCurve(50, paidApr, irm)
    expect(curve.baseApr).toBeCloseTo(curve.points.find((p) => p.utilization === 0)!.apr, 6)
    expect(curve.baseApr).toBeGreaterThanOrEqual(0)
  })

  it("matches Aave two-slope APR at a known point when base is not re-anchored", () => {
    // Base 0.25, U*=80, S1=4, S2=60 → at 45.5%: 0.25 + 4*(45.5/80) = 2.525
    expect(
      borrowAprAtUtilization(45.5, {
        optimalUtilizationPct: 80,
        slopeBelowOptimalPct: 4,
        slopeAboveOptimalPct: 60,
        baseBorrowRatePct: 0.25,
      }),
    ).toBeCloseTo(2.525, 5)
  })

  it("borrowDeltaUsdToUtilization is zero at current util and scales with target", () => {
    const suppliedUsd = 10_000_000
    const borrowedUsd = 6_293_000 // 62.93%
    expect(borrowDeltaUsdToUtilization(62.93, borrowedUsd, suppliedUsd)).toBeCloseTo(0, 4)
    expect(borrowDeltaUsdToUtilization(82, borrowedUsd, suppliedUsd)).toBeCloseTo(1_907_000, 0)
    expect(borrowDeltaUsdToUtilization(50, borrowedUsd, suppliedUsd)).toBeLessThan(0)
  })

  it("probeInterestRateModel returns anchored APR and matching borrow delta", () => {
    const anchor = { utilization: 50, apr: 8 }
    const { borrowedUsd, suppliedUsd } = resolveMarketLiquidityUsd({
      utilizationPct: 50,
      borrowedUsd: 5_000_000,
    })
    const probe = probeInterestRateModel({
      utilizationPct: 50,
      irm,
      anchor,
      borrowedUsd,
      suppliedUsd,
    })
    expect(probe.borrowAprPct).toBeCloseTo(8, 6)
    expect(probe.borrowDeltaUsd).toBeCloseTo(0, 4)
  })
})

describe("InterestRateModelCard SVG IRM", () => {
  it("draws an SVG kinked curve with dynamic Y ticks (not hardcoded 0–10)", () => {
    const source = readFileSync(
      resolve(__dirname, "../../../borrow/_detail/asset-sections/InterestRateModelCard.tsx"),
      "utf8",
    )
    expect(source).toMatch(/InterestRateModelChart/)
    expect(source).toMatch(/buildBorrowInterestRateCurve/)
    expect(source).toMatch(/probeInterestRateModel/)
    expect(source).not.toMatch(/const Y_TICKS = \[0, 5, 10\]/)
    expect(source).not.toMatch(/HTMLCanvasElement/)
    expect(source).toMatch(/detail\.interestRateModel/)
  })

  it("chart stays interactive with a shared probe calculator", () => {
    const chart = readFileSync(
      resolve(__dirname, "../../../borrow/_detail/asset-sections/InterestRateModelChart.tsx"),
      "utf8",
    )
    expect(chart).toMatch(/onPointerMove/)
    expect(chart).toMatch(/interest-rate-model-tooltip/)
  })
})
