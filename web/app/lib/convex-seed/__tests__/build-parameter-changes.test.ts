import { describe, expect, it } from "vitest"
import { buildParameterChangeRows } from "@/app/lib/convex-seed/build-parameter-changes"

const anchors = [
  { id: "collateralFactor", label: "Collateral factor", value: "78.00%" },
  { id: "depositCapacity", label: "Deposit capacity", value: "$211.0M" },
  { id: "borrowCapacity", label: "Borrow capacity", value: "$87.0M" },
]

describe("buildParameterChangeRows", () => {
  it("maps each product's risk-param rows to product-keyed changelog rows", () => {
    const rows = buildParameterChangeRows({
      borrow: [
        { slug: "bal-stable", kind: "pool", parameters: anchors },
        { slug: "usdc", kind: "asset", parameters: anchors },
      ],
      lend: [{ slug: "weth", parameters: anchors }],
      multiply: [{ slug: "aave-gho", parameters: anchors }],
      updatedAt: 1_700_000_000_000,
    })

    expect(rows.map((r) => r.product)).toEqual(["borrow", "borrow", "lend", "multiply"])
    expect(rows.every((r) => r.changes.length > 10)).toBe(true)
    expect(rows.every((r) => r.updatedAt === 1_700_000_000_000)).toBe(true)
  })

  it("uses the borrow kind to pick the listing row (pool → collateral config, asset → borrowable)", () => {
    const rows = buildParameterChangeRows({
      borrow: [
        { slug: "bal-stable", kind: "pool", parameters: anchors },
        { slug: "usdc", kind: "asset", parameters: anchors },
      ],
      lend: [],
      multiply: [],
      updatedAt: 0,
    })
    const pool = rows.find((r) => r.slug === "bal-stable")!.changes.at(-1)!
    const asset = rows.find((r) => r.slug === "usdc")!.changes.at(-1)!
    expect(pool.parameter).toBe("Collateral configuration")
    expect(asset.parameter).toBe("Borrowable")
  })

  it("anchors the newest capacity change to the grid value", () => {
    const [row] = buildParameterChangeRows({
      borrow: [{ slug: "usdc", kind: "asset", parameters: anchors }],
      lend: [],
      multiply: [],
      updatedAt: 0,
    })
    const cap = row!.changes.find((c) => c.parameter === "Deposit capacity")!
    expect(cap.current).toBe("$211.0M")
  })
})
