import { describe, expect, it } from "vitest"
import { accountLiquidationThresholdPct } from "@/app/lib/borrow-system/dashboard-selectors"

describe("accountLiquidationThresholdPct", () => {
  it("is the liquidation value over the collateral value", () => {
    expect(accountLiquidationThresholdPct(3380, 4225)).toBeCloseTo(80)
  })

  it("is undefined without collateral", () => {
    expect(accountLiquidationThresholdPct(0, 0)).toBeUndefined()
  })
})
