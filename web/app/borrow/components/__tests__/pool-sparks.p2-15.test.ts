import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"

describe("Mobile pool spark differentiation", () => {
  it("P2-15: pools carry per-id trend series for distinct mobile sparks", () => {
    const borrowSim = readFileSync(resolve(__dirname, "../../../lib/borrow-sim.ts"), "utf8")
    expect(borrowSim).toMatch(/trendValues: buildPoolTrendValues\(id\)/)
    const pools = BORROW_POOL_CATALOG.slice(0, 8)
    const signatures = new Set(pools.map((pool) => (pool.trendValues ?? []).join(",")))
    expect(signatures.size).toBeGreaterThan(1)
  })
})
