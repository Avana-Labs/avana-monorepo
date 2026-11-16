import { describe, expect, it } from "vitest"
import { syncQuickStatsRiskPremium } from "@/app/lib/borrow-detail/convex-detail"
import { formatRiskPremium } from "@/app/lib/borrow-market-rows"
import type { QuickStat } from "@/app/lib/borrow-detail/types"

const stats = (riskPremium: string): QuickStat[] => [
  { id: "riskPremium", label: "Risk premium", value: riskPremium },
  { id: "totalSupplied", label: "Total Supplied", value: "$1.0M" },
]

describe("syncQuickStatsRiskPremium", () => {
  it("restates the Risk exposure quick stat from the Risk assessment premium", () => {
    // The mock/catalog quick stat says +1.06%, the risk card premium is 68 bps (+0.68%).
    const out = syncQuickStatsRiskPremium(stats("+1.06%"), 68)
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe(formatRiskPremium(68))
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe("0.68% of base rate")
  })

  it("uses the exact same premium the Risk assessment card renders (single source)", () => {
    const premiumBps = 181
    const out = syncQuickStatsRiskPremium(stats("+0.00%"), premiumBps)
    // Both surfaces use the identical premiumBps, as a share of the base rate.
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe(formatRiskPremium(premiumBps))
  })

  it("leaves other quick stats untouched", () => {
    const out = syncQuickStatsRiskPremium(stats("+1.06%"), 68)
    expect(out.find((s) => s.id === "totalSupplied")?.value).toBe("$1.0M")
  })
})
