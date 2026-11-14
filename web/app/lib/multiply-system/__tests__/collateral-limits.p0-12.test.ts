import { describe, expect, it } from "vitest"
import { maxMultiplyCollateralAmount } from "@/app/lib/multiply-system/collateral-limits"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("multiply collateral max", () => {
  it("p0-12: Max uses wallet balance, not a hardcoded $12,500 budget constant", () => {
    const source = readFileSync(resolve(__dirname, "../collateral-limits.ts"), "utf8")
    expect(source).not.toMatch(/12_500|12500/)
    expect(maxMultiplyCollateralAmount(1_000_000, 100, 2_000)).toBeCloseTo(20, 6)
    expect(maxMultiplyCollateralAmount(1_000_000, 100, Number.POSITIVE_INFINITY)).toBeCloseTo(10_000, 6)
  })
})
