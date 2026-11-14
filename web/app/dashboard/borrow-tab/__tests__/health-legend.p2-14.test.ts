import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("SuppliesHealthFactorCard legend", () => {
  it("P2-14: inactive health legend dots keep their band colors", () => {
    const source = readFileSync(resolve(__dirname, "../supplies-table.tsx"), "utf8")
    expect(source).toMatch(/isActive \? zone\.color : cn\(zone\.color, "opacity-40"\)/)
    expect(source).not.toMatch(/isActive \? zone\.color : "bg-muted-foreground\/40"/)
  })
})
