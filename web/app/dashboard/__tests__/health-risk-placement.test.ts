import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

function source(path: string) {
  return readFileSync(resolve(__dirname, path), "utf8")
}

describe("Dashboard health warning placement", () => {
  it("does not render a health warning above the portfolio snapshot", () => {
    const dashboard = source("../dashboard-page-client.tsx")

    expect(dashboard).not.toContain("<HealthRiskBanner")
    expect(dashboard).not.toContain("healthRisk")
  })

  it("places each warning directly beneath its product health heading", () => {
    const borrow = source("../_rewards-components/borrow-account-section.tsx")
    const multiply = source("../_rewards-components/multiply-account-section.tsx")

    expect(borrow).toMatch(/t\("Borrow Health"\)[\s\S]*?<HealthRiskBanner[^>]+product="borrow"/)
    expect(multiply).toMatch(/t\("Multiply Health"\)[\s\S]*?<HealthRiskBanner[^>]+product="multiply"/)
  })
})
