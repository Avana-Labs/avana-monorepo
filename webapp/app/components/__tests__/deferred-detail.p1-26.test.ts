import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("DeferredDetailContent", () => {
  it("p1-26: default placeholder is compact, not a 1200px gray slab", () => {
    const source = readFileSync(resolve(__dirname, "../detail-page-primitives.tsx"), "utf8")
    expect(source).not.toMatch(/min-h-\[1200px\]/)
    expect(source).toMatch(/min-h-\[120px\]/)
    expect(source).toMatch(/animate-pulse/)
  })
})

describe("DeferredDetailContent mount distance", () => {
  it("mounts the analytics stack a full screen ahead so its lazy sections pop in off screen", async () => {
    const { DEFERRED_DETAIL_ROOT_MARGIN } = await import("../detail-page-primitives")
    expect(DEFERRED_DETAIL_ROOT_MARGIN).toBe("1000px 0px")
  })
})
