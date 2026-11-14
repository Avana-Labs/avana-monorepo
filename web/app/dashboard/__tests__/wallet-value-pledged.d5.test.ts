import { describe, expect, it } from "vitest"
import { sumWalletValueUsd } from "@/app/dashboard/dashboard-wallet-tab"

describe("Wallet Value sums the unallocated wallet rows it is given", () => {
  it("sums free wallet holdings (callers pre-filter to sourceType 'wallet')", () => {
    // The Wallet tab now passes only sourceType "wallet" rows; product buckets
    // (lend/borrow/multiply) live on their own tabs and never reach this helper.
    const rows = [
      { valueUsd: 300, sourceLabel: "Wallet" },
      { valueUsd: 193.65, sourceLabel: "Wallet" },
    ]
    expect(sumWalletValueUsd(rows)).toBeCloseTo(493.65, 2)
  })

  it("is a plain sum (no per-row exclusions of its own)", () => {
    const rows = [
      { valueUsd: 100, sourceLabel: "Wallet" },
      { valueUsd: 50, sourceLabel: "Wallet" },
    ]
    expect(sumWalletValueUsd(rows)).toBe(150)
  })
})
