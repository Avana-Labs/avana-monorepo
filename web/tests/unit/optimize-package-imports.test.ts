import { readFileSync } from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

/**
 * Guard: the Hugeicons packages must stay in Next's `optimizePackageImports`. The app funnels
 * ~76 icons through one barrel (app/components/icons.tsx) consumed by 40+ files; without this
 * transform a one-icon import can pull the whole icon module into the shared route chunk. Read
 * as text (not by importing the config, which executes CSP/env logic) so the guard is hermetic.
 */
describe("next.config optimizePackageImports", () => {
  const config = readFileSync(path.resolve(__dirname, "../../next.config.mjs"), "utf8")
  // Match the config KEY (with colon), not prose mentioning the option in a comment.
  const line = config.split("\n").find((l) => l.includes("optimizePackageImports:")) ?? ""

  it("tree-shakes the Hugeicons barrels", () => {
    expect(line).toContain("@hugeicons/react")
    expect(line).toContain("@hugeicons/core-free-icons")
  })
})
