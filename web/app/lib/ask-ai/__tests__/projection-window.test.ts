import { describe, expect, it } from "vitest"
import { projectionDaysFromPrompt } from "../projection-window"

describe("projectionDaysFromPrompt", () => {
  it.each([
    ["next 30 days", 30],
    ["over 30-day period", 30],
    ["next 2 weeks", 14],
    ["over 3 months", 90],
    ["next month", 30],
    ["next week", 7],
  ])("resolves %j to %d days", (prompt, expected) => {
    expect(projectionDaysFromPrompt(prompt)).toBe(expected)
  })

  it("uses the annual default only when no horizon is stated", () => {
    expect(projectionDaysFromPrompt("How much will my Lend positions earn?")).toBe(365)
  })
})
