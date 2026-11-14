import { describe, expect, it } from "vitest"
import { isAnalyticsBeaconRejection } from "../suppress-beacon-errors"

describe("isAnalyticsBeaconRejection", () => {
  it("matches the Vercel analytics beacon 'Failed to fetch' rejection", () => {
    expect(isAnalyticsBeaconRejection(new TypeError("Analytics SDK: Failed to fetch (AnalyticsSDKApiError)"))).toBe(
      true,
    )
    expect(isAnalyticsBeaconRejection("Analytics SDK: TypeError: Failed to fetch")).toBe(true)
    expect(isAnalyticsBeaconRejection(new TypeError("Failed to fetch /_vercel/insights/event"))).toBe(true)
    expect(isAnalyticsBeaconRejection({ message: "Speed Insights: Load failed" })).toBe(true)
  })

  it("does not match unrelated fetch failures (they must still surface)", () => {
    expect(isAnalyticsBeaconRejection(new TypeError("Failed to fetch"))).toBe(false)
    expect(isAnalyticsBeaconRejection(new Error("Convex query failed to fetch"))).toBe(false)
    expect(isAnalyticsBeaconRejection("some other error")).toBe(false)
    expect(isAnalyticsBeaconRejection(null)).toBe(false)
    expect(isAnalyticsBeaconRejection(undefined)).toBe(false)
  })
})
