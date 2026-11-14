import { describe, expect, it } from "vitest"
import { calculateMaxLeverageApy } from "@/app/lib/multiply-engine/formulas"
import {
  MULTIPLY_MARKET_ROWS,
  MULTIPLY_TOKEN_BORROW_APYS,
  MULTIPLY_TOKEN_SUPPLY_APYS,
  buildMultiplyMarketRow,
} from "@/app/lib/multiply-sim"

function parsePct(value: string) {
  return Number.parseFloat(value.replace("%", ""))
}

function parseFactor(value: string) {
  return Number.parseFloat(value.replace("x", ""))
}

describe("multiply-sim loop metrics (E3)", () => {
  it("never produces a non-finite max leverage (guards divide-by-zero at lt → 1)", () => {
    for (const row of MULTIPLY_MARKET_ROWS) {
      const leverage = parseFactor(row.rewardRows?.[0]?.value ?? "")
      expect(Number.isFinite(leverage)).toBe(true)
      expect(leverage).toBeGreaterThanOrEqual(1)
    }
  })

  it("stays finite even when the liquidation threshold is a degenerate 1.0 (or 0)", () => {
    // These would have divided by zero (1/(1-1) = Infinity) or blown up under the old
    // inline formula; the guarded path must return a finite, ≥1 leverage instead.
    const at100 = buildMultiplyMarketRow("AAVE", "GHO", { liquidationThreshold: 1 })
    expect(at100).not.toBeNull()
    expect(Number.isFinite(parseFactor(at100!.rewardRows![0]!.value))).toBe(true)
    expect(Number.isFinite(parsePct(at100!.apy))).toBe(true)
  })

  it("derives the loop APY from the shared calculateMaxLeverageApy (one loop-APY source)", () => {
    for (const row of MULTIPLY_MARKET_ROWS) {
      const leverage = parseFactor(row.rewardRows?.[0]?.value ?? "")
      const supplyApy =
        (MULTIPLY_TOKEN_SUPPLY_APYS[row.protocol as keyof typeof MULTIPLY_TOKEN_SUPPLY_APYS]
          ? Number.parseFloat(MULTIPLY_TOKEN_SUPPLY_APYS[row.protocol as keyof typeof MULTIPLY_TOKEN_SUPPLY_APYS]!)
          : 0) / 100
      const borrowApy =
        (MULTIPLY_TOKEN_BORROW_APYS[row.asset as keyof typeof MULTIPLY_TOKEN_BORROW_APYS]
          ? Number.parseFloat(MULTIPLY_TOKEN_BORROW_APYS[row.asset as keyof typeof MULTIPLY_TOKEN_BORROW_APYS]!)
          : 0) / 100
      // `leverage` is parsed back from the 2-decimal display factor, so allow for that
      // rounding; the point is that ONE formula (calculateMaxLeverageApy) produces the APY.
      const expected = calculateMaxLeverageApy({ supplyApy, borrowApy, safeMaxMultiplier: leverage }) * 100
      expect(parsePct(row.apy)).toBeCloseTo(expected, 1)
    }
  })
})
