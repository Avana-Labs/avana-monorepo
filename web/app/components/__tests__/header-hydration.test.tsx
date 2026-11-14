import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("header hydration", () => {
  it("renders lazy search on every breakpoint without a mounted placeholder swap", () => {
    const source = readFileSync(resolve(__dirname, "../header.tsx"), "utf8")
    expect(source).toMatch(/<LazySearchCommand \/>/)
    expect(source).toMatch(/<LazySearchCommandIconOnly tone="brand" \/>/)
    expect(source).not.toMatch(/SearchCommandPlaceholder/)
    expect(source).not.toMatch(/SearchCommandIconPlaceholder/)
    expect(source).not.toMatch(/mounted \? <LazySearchCommand/)
  })
})
