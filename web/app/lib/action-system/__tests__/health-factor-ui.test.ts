import { describe, expect, it } from "vitest"
import {
  activeHealthFactorZoneIndex,
  healthFactorBarPositionPct,
  healthFactorToneFromAfter,
  healthFactorStatusLabel,
  isHealthFactorMetric,
  parseHealthFactorValue,
  resolveMetricTone,
} from "@/app/lib/action-system/health-factor-ui"

describe("health factor ui helpers", () => {
  it("detects health factor metric rows", () => {
    expect(isHealthFactorMetric("Health factor")).toBe(true)
    expect(isHealthFactorMetric("Health factor after", "health-factor")).toBe(true)
    expect(isHealthFactorMetric("Net balance")).toBe(false)
  })

  it("maps after values to the conservative 4-band tone scale", () => {
    expect(healthFactorToneFromAfter("4.39")).toBe("positive") // safe ≥ 2.5
    expect(healthFactorToneFromAfter("2.10")).toBe("warning") // moderate 1.75–2.5
    expect(healthFactorToneFromAfter("1.60")).toBe("warning") // watch 1.2–1.75
    expect(healthFactorToneFromAfter("1.10")).toBe("danger") // < 1.2
    expect(healthFactorToneFromAfter("1.02")).toBe("danger")
    expect(healthFactorToneFromAfter("∞")).toBe("positive")
  })

  it("parses health factor values and bands them", () => {
    expect(parseHealthFactorValue("4.39")).toBe(4.39)
    expect(parseHealthFactorValue("∞")).toBe(Number.POSITIVE_INFINITY)
    expect(activeHealthFactorZoneIndex(4.39)).toBe(0)
    expect(activeHealthFactorZoneIndex(Number.POSITIVE_INFINITY)).toBe(0)
    expect(activeHealthFactorZoneIndex(1.6)).toBe(2) // watch
    expect(activeHealthFactorZoneIndex(1.0)).toBe(3) // danger
    expect(healthFactorStatusLabel(3.0).label).toBe("Safe")
    expect(healthFactorStatusLabel(2.0).label).toBe("Moderate")
    expect(healthFactorStatusLabel(1.6).label).toBe("Watch")
    expect(healthFactorStatusLabel(1.05).label).toBe("At risk")
  })

  it("positions safer health factors toward the left of the bar", () => {
    expect(healthFactorBarPositionPct(Number.POSITIVE_INFINITY)).toBeLessThan(healthFactorBarPositionPct(3.0))
    expect(healthFactorBarPositionPct(3.0)).toBeLessThan(healthFactorBarPositionPct(2.0))
    expect(healthFactorBarPositionPct(2.0)).toBeLessThan(healthFactorBarPositionPct(1.6))
    expect(healthFactorBarPositionPct(1.6)).toBeLessThan(healthFactorBarPositionPct(1.05))
    expect(healthFactorBarPositionPct(4.22)).toBeLessThan(50)
    expect(healthFactorBarPositionPct(1.2)).toBeGreaterThan(50)
  })

  it("keeps moving the thumb across the whole safe range (repay keeps HF high)", () => {
    // Regression: the safe zone previously pinned every HF >= 4 to the same spot,
    // so the health bar never moved while repaying a comfortably-safe position
    // (e.g. 6.59 -> 6.85 -> infinity). Distinct safe HF values must map to
    // distinct, monotonically-decreasing positions (higher HF = further left).
    const p659 = healthFactorBarPositionPct(6.59)
    const p685 = healthFactorBarPositionPct(6.85)
    const p9 = healthFactorBarPositionPct(9.08)
    const pInf = healthFactorBarPositionPct(Number.POSITIVE_INFINITY)
    expect(p685).toBeLessThan(p659) // repaying more -> safer -> thumb moves left
    expect(p9).toBeLessThan(p685)
    expect(pInf).toBeLessThan(p9)
    // The movement is real, not a rounding artifact.
    expect(p659 - p685).toBeGreaterThan(0)
    expect(p659).not.toBe(p9)
  })

  it("prefers health factor tone over generic default", () => {
    expect(resolveMetricTone("Health factor", "default", "1.60", "hf")).toBe("warning")
  })
})
