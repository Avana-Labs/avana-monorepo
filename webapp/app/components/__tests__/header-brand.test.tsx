import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { cleanup, render } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { HeaderBrand, MobileHeaderBrand } from "@/app/components/header-brand"

afterEach(() => cleanup())

describe("header brand", () => {
  it.each([
    ["desktop", HeaderBrand],
    ["mobile", MobileHeaderBrand],
  ])("shows only the Avana logo on %s, with no testnet label", (_name, Brand) => {
    const { container } = render(<Brand />)
    expect(container.textContent).not.toMatch(/testnet/i)
    expect(container.querySelectorAll("img").length).toBeGreaterThan(0)
  })

  it("names the logo link Home", () => {
    const header = readFileSync(resolve(__dirname, "../header.tsx"), "utf8")
    expect(header).not.toMatch(/testnet/i)
    expect(header).toMatch(/aria-label=\{t\("Home"\)\}/)
  })
})
