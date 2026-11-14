import { describe, expect, it } from "vitest"
import { formatActionFeeSummary } from "@/app/lib/action-system/formatters"
import { ACTION_INFO_TOOLTIPS } from "@/app/lib/action-system/metric-tooltips"

describe("one honest fee story (#30)", () => {
  it("states the 15 bps Avana platform fee on the action amount, as the tooltip discloses", () => {
    // A flat "~$0.03" read the same for $100 and $5,000; the fee is 0.15% of the amount.
    expect(formatActionFeeSummary(1000, 0.24)).toBe("~ $1.50")
    expect(formatActionFeeSummary(5000)).toBe("~ $7.50")
    expect(formatActionFeeSummary(0, 0.24)).toBe("~ $0.00")
  })

  it("tooltip discloses the real 15 bps upfront Avana interface fee", () => {
    expect(ACTION_INFO_TOOLTIPS.fee).toMatch(/15 bps|0\.15%/)
  })
})
