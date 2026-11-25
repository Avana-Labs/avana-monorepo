import { describe, expect, it } from "vitest"
import { getProcessingTitle } from "@/app/lib/action-system/action-page-labels"

describe("getProcessingTitle", () => {
  it("p1-27: Pledge maps to Pledging, never Pledgeing", () => {
    expect(getProcessingTitle("Pledge", "$1.00")).toBe("Pledging $1.00")
    expect(getProcessingTitle("Pledge", "$1.00")).not.toMatch(/Pledgeing/)
  })
})
