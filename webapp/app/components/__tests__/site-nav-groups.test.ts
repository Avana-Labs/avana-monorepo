import { describe, expect, it } from "vitest"
import { personalDesktopHeaderLinks, PRIMARY_HEADER_LINK_COUNT } from "@/app/components/site-nav"

describe("desktop header links", () => {
  it("lists Swap, Lend, Borrow and Dashboard as plain text product links", () => {
    const primary = personalDesktopHeaderLinks.slice(0, PRIMARY_HEADER_LINK_COUNT)
    expect(primary.map((link) => link.label)).toEqual(["Swap", "Lend", "Borrow", "Dashboard"])
    expect(primary.map((link) => link.href)).toEqual(["/", "/lend", "/borrow", "/dashboard"])
    expect(primary.every((link) => !link.icon)).toBe(true)
    expect(personalDesktopHeaderLinks.slice(PRIMARY_HEADER_LINK_COUNT)).toEqual([])
  })
})
