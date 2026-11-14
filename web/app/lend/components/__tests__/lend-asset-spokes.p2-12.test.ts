import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("Lend asset table on every viewport", () => {
  it("renders the shared table on phones instead of a separate card view", () => {
    const source = readFileSync(resolve(__dirname, "../lend-asset-spokes.tsx"), "utf8")
    expect(source).not.toMatch(/function AssetCardView/)
    expect(source).not.toMatch(/MarketMobileCard/)
    expect(source).not.toMatch(/useMediaQuery/)
    // The # column hides on phones so the pinned asset column starts at the edge.
    expect(source).toMatch(/TABLE_INDEX_PHONE_HIDDEN/)
  })

  it("keeps the desktop action column compact instead of leaving excess space on the right", () => {
    const source = readFileSync(resolve(__dirname, "../lend-asset-spokes.tsx"), "utf8")
    const layout = source.match(/const LEND_TABLE_LAYOUT = tableColumnLayout\(\[([\s\S]*?)\]\)/)?.[1] ?? ""
    const kinds = [...layout.matchAll(/"([a-z0-9]+)"/g)].map(([, kind]) => kind)

    // Shared layout: the action column is the fixed single-button kind, not a stretchy share.
    expect(kinds).toHaveLength(7)
    expect(kinds.at(-1)).toBe("action")
  })
})
