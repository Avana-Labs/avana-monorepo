import { describe, expect, it } from "vitest"
import { getActionDescriptor } from "@/app/lib/action-system/contracts"

describe("action-system contracts", () => {
  it("uses Avana action configure subtitles", () => {
    expect(getActionDescriptor("borrow", "borrow").subtitle).toContain("Configure and review")
    expect(getActionDescriptor("lend", "withdraw").subtitle).toContain("Configure and review")
  })
})
