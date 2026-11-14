import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("mobile horizontal rail", () => {
  it("keeps snapped items inside a gutter and exposes overflow with an edge fade", () => {
    const rail = readFileSync(resolve(__dirname, "../horizontal-rail.ts"), "utf8")
    const borrowHero = readFileSync(resolve(__dirname, "../../../borrow/borrow-page-hero.tsx"), "utf8")

    expect(rail).toMatch(/scroll-px-3/)
    expect(rail).toMatch(/mask-image:linear-gradient/)
    expect(rail).toMatch(/overscroll-x-contain/)
    expect(borrowHero).toMatch(/MOBILE_EDGE_RAIL_CLASS/)
  })
})
