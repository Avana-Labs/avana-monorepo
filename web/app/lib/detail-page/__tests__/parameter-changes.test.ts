import { describe, expect, it } from "vitest"
import {
  buildParameterChangelog,
  type BuildParameterChangelogInput,
  type ParameterChangeCategory,
} from "@/app/lib/detail-page/parameter-changes"

const VALID_CATEGORIES: ParameterChangeCategory[] = ["Risk Management", "Domain Admin", "Listing", "Emergency"]

function borrowAssetInput(slug: string): BuildParameterChangelogInput {
  return {
    slug,
    product: "borrow-asset",
    listedAt: "2024-03-18",
    proposalHref: "https://gov.example/proposal",
    anchors: [
      { id: "collateralFactor", label: "Collateral factor", value: "78.00%" },
      { id: "liquidationThreshold", label: "Liquidation threshold", value: "83.00%" },
      { id: "depositCapacity", label: "Deposit capacity", value: "$211.0M" },
      { id: "borrowCapacity", label: "Borrow capacity", value: "$87.0M" },
      { id: "liquidationPenalty", label: "Liquidation penalty", value: "5.00% - 5.55%" },
      { id: "targetHealthFactor", label: "Target health factor", value: "1.28" },
      { id: "collateralRisk", label: "Collateral risk", value: "5.00%" },
      { id: "oracle", label: "Oracle source", value: "Chainlink" },
    ],
  }
}

describe("buildParameterChangelog", () => {
  it("always returns 11-32 entries so the 10-per-page pager is exercised", () => {
    for (const slug of [
      "gho",
      "usdc",
      "weth",
      "wbtc",
      "bal-stable:gho",
      "aave-gho",
      "reth",
      "cbeth",
      "rare-market-xyz",
    ]) {
      const rows = buildParameterChangelog(borrowAssetInput(slug))
      expect(rows.length, `slug ${slug}`).toBeGreaterThan(10)
      expect(rows.length, `slug ${slug}`).toBeLessThanOrEqual(32)
    }
  })

  it("is deterministic — same input yields identical output", () => {
    const a = buildParameterChangelog(borrowAssetInput("weth"))
    const b = buildParameterChangelog(borrowAssetInput("weth"))
    expect(a).toEqual(b)
  })

  it("varies count across slugs (not a constant)", () => {
    const counts = new Set(
      ["a", "b", "c", "d", "e", "f", "g", "h"].map((s) => buildParameterChangelog(borrowAssetInput(s)).length),
    )
    expect(counts.size).toBeGreaterThan(1)
  })

  it("orders rows strictly newest-first by date", () => {
    const rows = buildParameterChangelog(borrowAssetInput("usdc"))
    for (let i = 1; i < rows.length; i++) {
      expect(rows[i - 1]!.date >= rows[i]!.date, `row ${i}`).toBe(true)
    }
  })

  it("anchors the newest change of a parameter to its current grid value", () => {
    const rows = buildParameterChangelog(borrowAssetInput("weth"))
    // Deposit capacity current value must appear as the `current` of its most-recent change.
    const capRows = rows.filter((r) => r.parameter === "Deposit capacity")
    expect(capRows.length).toBeGreaterThan(0)
    expect(capRows[0]!.current).toBe("$211.0M")
    const cfRows = rows.filter((r) => r.parameter === "Collateral factor")
    expect(cfRows[0]!.current).toBe("78.00%")
  })

  it("ends with a Listing row as the oldest entry", () => {
    const rows = buildParameterChangelog(borrowAssetInput("gho"))
    const last = rows.at(-1)!
    expect(last.category).toBe("Listing")
    expect(last.date).toBe("2024-03-18")
  })

  it("only emits known categories and fills every required field", () => {
    const rows = buildParameterChangelog(borrowAssetInput("cbeth"))
    for (const row of rows) {
      expect(VALID_CATEGORIES).toContain(row.category)
      expect(row.parameter).toBeTruthy()
      expect(row.previous).toBeTruthy()
      expect(row.current).toBeTruthy()
      expect(row.source).toBeTruthy()
      expect(row.executor).toBeTruthy()
      expect(row.href).toBe("https://gov.example/proposal")
      expect(row.id).toMatch(/-chg-\d+$/)
    }
  })

  it("uses a borrowable listing row for borrow assets and collateral config elsewhere", () => {
    const asset = buildParameterChangelog(borrowAssetInput("gho")).at(-1)!
    expect(asset.parameter).toBe("Borrowable")
    const pool = buildParameterChangelog({ ...borrowAssetInput("bal-stable"), product: "borrow-pool" }).at(-1)!
    expect(pool.parameter).toBe("Collateral configuration")
  })

  it("produces unique ids", () => {
    const rows = buildParameterChangelog(borrowAssetInput("usdc"))
    expect(new Set(rows.map((r) => r.id)).size).toBe(rows.length)
  })

  it("gives every row a deterministic Etherscan tx link when no proposalHref is set", () => {
    const input = { ...borrowAssetInput("usdc") }
    delete (input as { proposalHref?: string }).proposalHref
    const a = buildParameterChangelog(input)
    const b = buildParameterChangelog(input)
    for (const row of a) {
      expect(row.href).toMatch(/^https:\/\/etherscan\.io\/tx\/0x[0-9a-f]{64}$/)
    }
    // Deterministic across runs.
    expect(a.map((r) => r.href)).toEqual(b.map((r) => r.href))
  })
})
