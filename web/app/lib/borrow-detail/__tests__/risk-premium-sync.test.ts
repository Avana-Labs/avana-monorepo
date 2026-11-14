import { describe, expect, it } from "vitest"
import { syncQuickStatsRiskPremium } from "@/app/lib/borrow-detail/convex-detail"
import { formatBpsAsPct } from "@/app/lib/borrow-detail/allocation"
import type { QuickStat } from "@/app/lib/borrow-detail/types"

const stats = (riskPremium: string): QuickStat[] => [
  { id: "riskPremium", label: "Risk premium", value: riskPremium },
  { id: "totalSupplied", label: "Total Supplied", value: "$1.0M" },
]

describe("syncQuickStatsRiskPremium", () => {
  it("restates the Risk exposure quick stat from the Risk assessment premium", () => {
    // The mock/catalog quick stat says +1.06%, the risk card premium is 68 bps (+0.68%).
    const out = syncQuickStatsRiskPremium(stats("+1.06%"), 68)
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe(formatBpsAsPct(68))
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe("+0.68%")
  })

  it("uses the exact same premium the Risk assessment card renders (single source)", () => {
    const premiumBps = 181
    const out = syncQuickStatsRiskPremium(stats("+0.00%"), premiumBps)
    // Both surfaces format the identical premiumBps with formatBpsAsPct.
    expect(out.find((s) => s.id === "riskPremium")?.value).toBe(formatBpsAsPct(premiumBps))
  })

  it("leaves other quick stats untouched", () => {
    const out = syncQuickStatsRiskPremium(stats("+1.06%"), 68)
    expect(out.find((s) => s.id === "totalSupplied")?.value).toBe("$1.0M")
  })
})
