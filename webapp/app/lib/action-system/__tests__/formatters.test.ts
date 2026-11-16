import { describe, expect, it } from "vitest"
import {
  formatActionApproxUsd,
  formatActionBeforeAfter,
  formatActionHealthFactor,
  formatActionFeeSummary,
  formatActionNetworkFee,
  formatActionUsd,
  formatActionUsdBeforeAfter,
} from "@/app/lib/action-system/formatters"

describe("action formatters", () => {
  it("formats billion-scale TVL with compact suffix", () => {
    expect(formatActionUsd(6_885_000_000, { compact: true })).toBe("$6.9B")
  })

  it("avoids million-scale billion bug seen on borrow hero", () => {
    expect(formatActionUsd(6_885_000_000, { compact: true })).not.toBe("$6885.0M")
  })

  it("formats health factor without long tails", () => {
    expect(formatActionHealthFactor(1.999999999999)).toBe("2.00")
    expect(formatActionHealthFactor(2.9)).toBe("2.90")
  })

  it("formats before and after rows for review metrics", () => {
    expect(formatActionUsdBeforeAfter(2.9, 1.9)).toBe("$2.90 → $1.90")
    expect(formatActionBeforeAfter("1.36%", "0.79%")).toBe("1.36% → 0.79%")
  })

  it("formats network fee for Avana action pages", () => {
    expect(formatActionNetworkFee(0.04)).toBe("~ $0.04")
  })

  it("fee summary is the action's front-end fee, 10 bps by default (#30, #F1, Q-409)", () => {
    expect(formatActionFeeSummary("borrow", 1000)).toBe("~ $1.00")
    expect(formatActionFeeSummary("supply", 100)).toBe("~ $0.10")
    expect(formatActionFeeSummary("supply", 0)).toBe("~ $0.00")
  })

  it("formats approx usd under amount input", () => {
    expect(formatActionApproxUsd(1)).toBe("$1.00")
  })
})
