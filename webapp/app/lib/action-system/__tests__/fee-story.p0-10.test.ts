import { afterEach, describe, expect, it } from "vitest"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"
import { formatActionFeeSummary } from "@/app/lib/action-system/formatters"
import { ACTION_INFO_TOOLTIPS } from "@/app/lib/action-system/metric-tooltips"
import { fillFeeRate, setFrontendFeeRules, statedFeeBps } from "@/app/lib/fees/front-end-fee"

describe("one honest fee story (#30, Q-409)", () => {
  afterEach(() => {
    setFrontendFeeRules(DEFAULT_FEE_RULES)
  })

  it("states the front-end fee from the fee rules on the action amount (10 bps by default)", () => {
    expect(formatActionFeeSummary("supply", 1000)).toBe("~ $1.00")
    expect(formatActionFeeSummary("borrow", 5000)).toBe("~ $5.00")
    expect(formatActionFeeSummary("supply", 0)).toBe("~ $0.00")
  })

  it("follows the rules from Convex: a per-action rate, an exempt action, fees off", () => {
    setFrontendFeeRules({ ...DEFAULT_FEE_RULES, actionBps: { repay: 20 }, exemptActions: ["withdraw"] })
    expect(formatActionFeeSummary("repay", 1000)).toBe("~ $2.00")
    expect(formatActionFeeSummary("withdraw", 1000)).toBe("~ $0.00")
    setFrontendFeeRules({ ...DEFAULT_FEE_RULES, enabled: false })
    expect(formatActionFeeSummary("supply", 1000)).toBe("~ $0.00")
  })

  it("charges nothing for claim, which is not a Q-409 action", () => {
    expect(formatActionFeeSummary("claim", 1000)).toBe("~ $0.00")
  })

  it("the tooltip states the configured rate", () => {
    expect(ACTION_INFO_TOOLTIPS.fee).toContain("A {bps} bps ({pct}%) upfront Avana interface fee")
    expect(fillFeeRate(ACTION_INFO_TOOLTIPS.fee!, statedFeeBps())).toMatch(/^A 10 bps \(0\.10%\) upfront/)
    expect(fillFeeRate("{bps} Basispunkten ({pct} %)", 10, "DE")).toBe("10 Basispunkten (0,10 %)")
  })
})
