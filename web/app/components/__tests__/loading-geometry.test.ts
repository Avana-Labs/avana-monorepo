import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("loading geometry", () => {
  it("matches the responsive Borrow discovery-card dimensions", () => {
    const source = readFileSync(resolve(__dirname, "../loading-states.tsx"), "utf8")

    expect(source).toContain("h-[172px] w-[19rem]")
    expect(source).toContain("md:h-[158px] md:w-80")
  })
})
