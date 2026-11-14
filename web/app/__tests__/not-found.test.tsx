import { cleanup, render, within } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import NotFound from "@/app/not-found"

afterEach(cleanup)

describe("NotFound recovery links (#141)", () => {
  it("leads with a Home link and never points to the retired /express route", () => {
    const { getByRole, queryByRole } = render(<NotFound />)

    const home = getByRole("link", { name: "Home" })
    expect(home).toHaveAttribute("href", "/")

    // /express is retired (404) — recovery links must not send users there.
    expect(queryByRole("link", { name: "Express" })).not.toBeInTheDocument()
    const allLinks = Array.from(document.querySelectorAll("a")).map((a) => a.getAttribute("href"))
    expect(allLinks).not.toContain("/express")
  })

  it("offers useful destination links", () => {
    const { getByRole } = render(<NotFound />)
    const nav = getByRole("navigation", { name: "Helpful links" })

    for (const [label, href] of [
      ["Borrow", "/borrow"],
      ["Lend", "/lend"],
      ["Multiply", "/multiply"],
      ["Dashboard", "/dashboard"],
    ] as const) {
      expect(within(nav).getByRole("link", { name: label })).toHaveAttribute("href", href)
    }
  })
})
