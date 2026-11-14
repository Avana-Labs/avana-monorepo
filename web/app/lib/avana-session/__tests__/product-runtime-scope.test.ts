import { describe, expect, it } from "vitest"
import { resolveProductRuntimeScope } from "@/app/lib/avana-session/product-runtime-scope"


describe("market snapshot hydrator price source", () => {
  it("does not open a duplicate getPriceSnapshot subscription", async () => {
    const { readFileSync } = await import("node:fs")
    const { resolve } = await import("node:path")
    const source = readFileSync(resolve(__dirname, "../convex-market-snapshot-hydrators.tsx"), "utf8")
    expect(source).not.toMatch(/api\.prices\./)
    expect(source).toMatch(/usePriceFor/)
    expect(source).toMatch(/scope\.marketSnapshots \? \{\} : "skip"/)
  })
})
