import { describe, expect, it } from "vitest"
import { formatSectionCount } from "@/app/lib/ui/section-count"

describe("section count labels", () => {
  it("P2-11: uses singular forms when count is 1", () => {
    expect(formatSectionCount(1, "asset", "assets")).toBe("1 asset")
    expect(formatSectionCount(1, "loan", "loans")).toBe("1 loan")
    expect(formatSectionCount(2, "asset", "assets")).toBe("2 assets")
  })
})
