import { describe, expect, it } from "vitest"
import { personalDesktopHeaderLinks } from "@/app/components/site-nav"

describe("primary nav", () => {
  it("p1-09: includes Umbrella in the primary nav", () => {
    expect(personalDesktopHeaderLinks.some((link) => link.href === "/umbrella")).toBe(true)
    expect(personalDesktopHeaderLinks.map((link) => link.label)).toContain("Umbrella")
  })
})
