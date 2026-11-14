import { describe, expect, it } from "vitest"
import { shouldFailClosedWithoutSnapshots } from "@/app/lib/borrow-detail/live-fallback"

describe("shouldFailClosedWithoutSnapshots", () => {
  it("fails closed in live mode when Convex snapshots are empty", () => {
    expect(shouldFailClosedWithoutSnapshots("live", 0)).toBe(true)
  })

  it("allows catalog fallback in mock mode even with empty snapshots", () => {
    expect(shouldFailClosedWithoutSnapshots("mock", 0)).toBe(false)
  })

  it("does not fail closed when live snapshots exist", () => {
    expect(shouldFailClosedWithoutSnapshots("live", 3)).toBe(false)
  })
})
