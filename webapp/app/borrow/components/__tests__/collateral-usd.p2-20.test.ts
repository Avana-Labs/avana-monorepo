import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("collateral table USD display", () => {
  it("P2-20: stops double-printing compact and full USD in collateral desktop cells", () => {
    const source = readFileSync(resolve(__dirname, "../collateral-pools-table.tsx"), "utf8")
    const desktop = source.slice(source.indexOf("function CollateralDesktopTable"))
    expect(desktop).not.toMatch(/compact\(pool\.tvlUsd\)[\s\S]{0,200}convert\(pool\.tvlUsd\)/)
    expect(desktop).not.toMatch(/compact\(pool\.availableUsd\)[\s\S]{0,200}convert\(pool\.availableUsd\)/)
  })

  it("keeps Available out of the collateral table columns", () => {
    const source = readFileSync(resolve(__dirname, "../collateral-pools-table.tsx"), "utf8")
    const row = source.slice(
      source.indexOf("const CollateralPoolRow"),
      source.indexOf("function CollateralDesktopTable"),
    )
    const desktop = source.slice(
      source.indexOf("function CollateralDesktopTable"),
      source.indexOf("export const CollateralPoolsTable"),
    )

    expect(desktop).not.toContain('t("AVAILABLE")')
    expect(desktop).not.toContain('"liquidity"')
    // Pending rows span the whole shared layout (7 columns: no Available or Premium column).
    expect(desktop).toContain("colSpan={COLLATERAL_TABLE_LAYOUT.widths.length}")
    const layout = source.slice(
      source.indexOf("const COLLATERAL_TABLE_LAYOUT"),
      source.indexOf("function CollateralDesktopTable"),
    )
    expect(layout.match(/^\s+"[a-z0-9]+",/gm)).toHaveLength(7)
    expect(row).not.toContain("pool.availableUsd")
  })
})
