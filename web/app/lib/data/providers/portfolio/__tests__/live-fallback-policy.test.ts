import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"

describe("portfolio live-source fallback policy", () => {
  it("never substitutes mock portfolio rows after a live fetch failure", () => {
    const source = readFileSync("app/lib/data/providers/portfolio/fetch-portfolio-page.ts", "utf8")

    expect(source).toContain("return loadFromSource(livePortfolioPageSource, input, options)")
    expect(source).not.toContain("loadWithAuthFallback({")
  })
})
