import { describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/borrow-system/liquidation-threshold", () => ({
  liquidationThresholdPctFromMaxLtvPct: (ltv: number) => (ltv === 65 ? 75 : ltv),
}))

import { liquidationThresholdCaption } from "../collateral-pools-table"

describe("Borrow table LT caption", () => {
  it("is hidden when the liquidation threshold equals the max LTV", () => {
    expect(liquidationThresholdCaption({ ltv: 80 })).toBeNull()
  })

  it("shows the threshold when it differs", () => {
    expect(liquidationThresholdCaption({ ltv: 65 })).toBe("75%")
  })
})
