import { cleanup, render } from "@testing-library/react"
import { afterEach, expect, it } from "vitest"
import { BrandLogo } from "@/app/components/brand-logo"

afterEach(cleanup)

// The header hides the wordmark below xl, but an eager high-priority <img> still downloads the
// 30KB PNG on every phone and competes with the LCP resource.
it("serves a 1px placeholder below xl when the wordmark is only shown from xl", () => {
  const { container } = render(<BrandLogo visibleFrom="xl" />)
  const source = container.querySelector("picture > source")
  expect(source?.getAttribute("media")).toBe("(max-width: 1279.98px)")
  expect(source?.getAttribute("srcset")).toMatch(/^data:image\/gif;base64,/)
  expect(container.querySelector("picture > img")?.getAttribute("alt")).toBe("Avana logo")
})

it("renders a plain eager wordmark by default", () => {
  const { container } = render(<BrandLogo />)
  expect(container.querySelector("picture")).toBeNull()
  expect(container.querySelector("img")?.getAttribute("loading")).toBe("eager")
})
