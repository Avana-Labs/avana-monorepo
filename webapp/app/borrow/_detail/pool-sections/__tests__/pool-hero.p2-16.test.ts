import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("PoolHero share actions", () => {
  it("P2-16: exposes hero share actions on mobile and drops Google/X search fallbacks", () => {
    const source = readFileSync(resolve(__dirname, "../PoolHero.tsx"), "utf8")
    expect(source).not.toMatch(/hidden shrink-0 items-center gap-2 self-center pl-5 lg:flex/)
    expect(source).not.toMatch(/google\.com\/search/)
    expect(source).not.toMatch(/x\.com\/search/)
    expect(source).toMatch(/detail\.hero\.explorerUrl/)
    expect(source).toMatch(/detail\.hero\.xUrl/)
  })
})
