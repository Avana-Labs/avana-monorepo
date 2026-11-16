import { describe, expect, it } from "vitest"
import { personalDesktopHeaderLinks, PRIMARY_HEADER_LINK_COUNT } from "@/app/components/site-nav"

describe("desktop header links", () => {
  it("keeps the product links on the left and Dashboard as the utility link on the right", () => {
    const primary = personalDesktopHeaderLinks.slice(0, PRIMARY_HEADER_LINK_COUNT).map((link) => link.label)
    const utility = personalDesktopHeaderLinks.slice(PRIMARY_HEADER_LINK_COUNT).map((link) => link.label)
    expect(primary).toEqual(["Express", "Lend", "Borrow"])
    expect(utility).toEqual(["Dashboard"])
  })
})
