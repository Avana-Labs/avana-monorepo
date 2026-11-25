import { describe, expect, it } from "vitest"
import { deriveHistoricalUtilization } from "@/app/lib/borrow-detail/convex-detail"
import type { Series } from "@/app/lib/borrow-detail/types"

// The asset detail page used to fetch `getHistoricalUtilization` alongside `getSupplyBorrow`.
// Both read the same 1Y window of the same asset's daily rows and both project
// `utilizationPct`, so the second call was a duplicate read (Convex billed both at 16.6 MB).
// The page now derives the series; these pin that the derived value is indistinguishable
// from what the dropped query returned.
const utilization: Series = {
  id: "kd72abc:sb:utilization",
  label: "Utilization",
  points: [
    { t: "2026-09-15", v: 41.2 },
    { t: "2026-09-16", v: 43.8 },
  ],
}

describe("deriveHistoricalUtilization", () => {
  it("restates the id to the historical-utilization suffix", () => {
    expect(deriveHistoricalUtilization(utilization)?.id).toBe("kd72abc:historical-utilization")
  })

  it("carries the points through untouched", () => {
    const derived = deriveHistoricalUtilization(utilization)
    expect(derived?.points).toEqual(utilization.points)
    expect(derived?.label).toBe("Utilization")
  })

  it("does not mutate the supplyBorrow series it derives from", () => {
    deriveHistoricalUtilization(utilization)
    expect(utilization.id).toBe("kd72abc:sb:utilization")
  })

  it("returns null when supplyBorrow produced no utilization series", () => {
    expect(deriveHistoricalUtilization(null)).toBeNull()
    expect(deriveHistoricalUtilization(undefined)).toBeNull()
  })

  it("leaves an id that does not carry the expected suffix alone", () => {
    const odd = { ...utilization, id: "empty" }
    expect(deriveHistoricalUtilization(odd)?.id).toBe("empty")
  })
})
