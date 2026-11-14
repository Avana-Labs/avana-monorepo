import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { formatActionHealthFactor } from "@/app/lib/action-system/formatters"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import { formatHealthFactor } from "@/app/lib/home-sim"

describe("health factor presentation unification", () => {
  it("p1-06: action and dashboard formatters share ∞ policy and decimals", () => {
    expect(formatActionHealthFactor(18_369.7)).toBe(formatHealthFactor(18_369.7))
    expect(formatActionHealthFactor(Number.POSITIVE_INFINITY)).toBe("∞")
    expect(formatActionHealthFactor(1.8)).toBe("1.80")
    expect(formatActionHealthFactor(null)).toBe("—")
  })

  it("p1-06: borrow preview mapper uses shared healthFactorBand thresholds", () => {
    const source = readFileSync(resolve(__dirname, "../action-system/adapters/borrow-preview-mapper.ts"), "utf8")

    expect(source).not.toMatch(/value < 1\.05\)/)
    expect(source).not.toMatch(/value < 1\.5\)/)
    expect(source).toMatch(/healthFactorBand/)
  })

  it("p1-06: multiply collateral table reuses shared formatHealthFactor", () => {
    const source = readFileSync(resolve(__dirname, "../../dashboard/multiply-collateral-table.tsx"), "utf8")

    expect(source).not.toMatch(/function formatHealthFactor\(/)
    expect(source).toMatch(/formatHealthFactor/)
  })

  it("p1-06: shared bands classify 1.05 / 1.15 / 1.2 consistently", () => {
    expect(healthFactorBand(1.05).id).toBe("danger")
    expect(healthFactorBand(1.15).id).toBe("danger")
    expect(healthFactorBand(1.2).id).toBe("watch")
    expect(healthFactorBand(1.05).tone).toBe("danger")
    expect(healthFactorBand(1.15).tone).toBe("danger")
    expect(healthFactorBand(1.25).tone).toBe("warning")
  })
})
