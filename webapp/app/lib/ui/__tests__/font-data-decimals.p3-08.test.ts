import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("font-data decimal tracking", () => {
  it("P3-08: summary metrics use normal tracking to avoid spaced decimals", () => {
    const tableTokens = readFileSync(resolve(__dirname, "../../ui/table-row-hover.ts"), "utf8")
    const metrics = readFileSync(resolve(__dirname, "../../../dashboard/dashboard-metric-section.tsx"), "utf8")
    expect(tableTokens).toMatch(/TABLE_CELL_NUMERIC[^\n]*tabular-nums/)
    expect(metrics).toMatch(/tracking-normal tabular-nums/)
    expect(metrics).not.toMatch(/tracking-\[-0\.04em\]/)
  })

  it("P3-08: tabular-nums uses proportional lining figures so commas/decimals stay tight", () => {
    const globals = readFileSync(resolve(__dirname, "../../../globals.css"), "utf8")
    expect(globals).toMatch(/\.tabular-nums\s*\{[^}]*font-variant-numeric:\s*lining-nums proportional-nums/s)
    expect(globals).toMatch(/\.tabular-nums\s*\{[^}]*white-space:\s*nowrap/s)
  })
})
