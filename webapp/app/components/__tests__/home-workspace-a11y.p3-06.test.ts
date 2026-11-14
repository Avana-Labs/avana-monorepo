import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("home workspace accessibility", () => {
  it("P3-06: names Express tabs in ariaLabel and shows visible hero metric labels", () => {
    const workspace = readFileSync(resolve(__dirname, "../home/home-workspace-card.tsx"), "utf8")
    const chart = readFileSync(resolve(__dirname, "../charts/market-hero-chart.tsx"), "utf8")
    expect(workspace).toMatch(/ariaLabel=\{t\("Express actions"\)\}/)
    expect(chart).not.toMatch(/sr-only/)
    expect(chart).toMatch(/text-\[12px\] font-medium uppercase/)
  })
})
