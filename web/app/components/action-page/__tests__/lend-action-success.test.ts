import { describe, expect, it } from "vitest"
import { lendSuccessMetrics } from "@/app/components/action-page/lend-action-page-client"

describe("lendSuccessMetrics", () => {
  it("reports the withdrawal received instead of the pre-action withdrawable balance", () => {
    const metrics = lendSuccessMetrics(
      [{ id: "withdrawable-balance", label: "Wallet withdrawable", value: "100 USDC" }],
      "withdraw",
      50,
      "USDC",
    )

    expect(metrics).toEqual([{ id: "withdrawable-balance", label: "Wallet received", value: "50 USDC" }])
  })
})

// Prod 2026-09-23: the review showed "Accrued earnings $0.30 → $0.28"; the receipt read $0.00 → $0.00.
describe("lendSuccessMetrics accrued earnings", () => {
  it("freezes the live accrued earnings at submit time", () => {
    const year = 365 * 24 * 3600 * 1000
    const [metric] = lendSuccessMetrics(
      [
        {
          id: "earnings",
          label: "Accrued earnings",
          value: "$0.00 → $0.00",
          liveUsd: {
            anchorMs: 0,
            before: { baseUsd: 0, ratePerYearUsd: 3.65 },
            after: { baseUsd: 0, ratePerYearUsd: 3.4 },
          },
        },
      ],
      "withdraw",
      25,
      "USDC",
      year / 12,
    )
    expect(metric?.value).toBe("$0.30 → $0.28")
    expect(metric?.liveUsd).toBeUndefined()
  })
})
