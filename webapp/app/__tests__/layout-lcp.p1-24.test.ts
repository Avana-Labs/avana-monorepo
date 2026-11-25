import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("root layout LCP", () => {
  it("p1-24: preloads Diatype with display:swap (loads before first paint, no flash, no preload warning)", () => {
    const source = readFileSync(resolve(__dirname, "../layout.tsx"), "utf8")
    // preload puts the font on the critical path so it is fetched well before first paint; with the
    // font already available when text paints, display:swap renders directly in Diatype — no
    // fallback->Diatype flash. The flash came from preload:false letting the font load ~800ms in;
    // preload (not optional) is what fixes it — and swap keeps the preload "used", avoiding the
    // "preloaded but not used" browser warning that optional produced when the font missed its window.
    expect(source).toMatch(/preload:\s*true/)
    expect(source).toMatch(/display:\s*"swap"/)
  })
})
