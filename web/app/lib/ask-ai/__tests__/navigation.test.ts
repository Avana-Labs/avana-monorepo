import { describe, expect, it } from "vitest"
import { askAIHref, resolveAskAICloseHref } from "../navigation"

describe("Ask AI navigation", () => {
  it("preserves the launch route", () => {
    expect(askAIHref("/borrow?tab=positions")).toBe("/ask?return=%2Fborrow%3Ftab%3Dpositions")
    expect(resolveAskAICloseHref("/borrow?tab=positions")).toBe("/borrow?tab=positions")
  })

  it.each([null, undefined, "", "https://evil.example", "//evil.example", "/ask", "/ask?thread=1"])(
    "falls back home for unsafe return value %s",
    (returnHref) => expect(resolveAskAICloseHref(returnHref)).toBe("/"),
  )

  // Values as they arrive from `searchParams.get("return")`: %5C decodes to a backslash and %09
  // to a tab, and browsers normalise both "/\host" and "/\t/host" to the off-site "//host".
  it.each(["/%5Cevil.example", "/%09/evil.example", "/%5C%5Cevil.example/path"])(
    "falls back home for an off-site redirect disguised as a path (%s)",
    (raw) => {
      const decoded = new URLSearchParams(`return=${raw}`).get("return")
      expect(resolveAskAICloseHref(decoded)).toBe("/")
    },
  )

  it("keeps a same-origin path with its query and hash", () => {
    expect(resolveAskAICloseHref("/lend/markets/eth?tab=activity#rates")).toBe("/lend/markets/eth?tab=activity#rates")
  })
})
