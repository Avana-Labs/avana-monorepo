// @vitest-environment node
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"

describe("the redemption rules the webapp reads", () => {
  it("import nothing, so the client bundle never pulls in Convex server code", () => {
    const source = readFileSync(join(process.cwd(), "..", "services/convex/convex/lib/redemptionRules.ts"), "utf8")
    expect(source).not.toMatch(/^\s*import\s/m)
  })
})
