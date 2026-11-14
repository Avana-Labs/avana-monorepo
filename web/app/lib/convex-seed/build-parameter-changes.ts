/**
 * Seed builder for the `parameterChanges` Convex table. Turns each product's
 * finalized Risk Parameters rows into a deterministic governance changelog via
 * `buildParameterChangelog`, so the newest change of every parameter reconciles
 * with the Risk Parameters grid the same market shows.
 */

import { buildParameterChangelog, type ProductKind } from "@/app/lib/detail-page/parameter-changes"

export type SeedParameterChangeRow = {
  product: "borrow" | "lend" | "multiply"
  slug: string
  changes: ReturnType<typeof buildParameterChangelog>
  updatedAt: number
}

type RiskParamRow = {
  slug: string
  kind?: "pool" | "asset"
  parameters: Array<{ id: string; label: string; value: string }>
}

function rowsFor(
  product: "borrow" | "lend" | "multiply",
  rows: RiskParamRow[],
  updatedAt: number,
): SeedParameterChangeRow[] {
  return rows.map((row) => {
    const generatorProduct: ProductKind =
      product === "borrow" ? (row.kind === "asset" ? "borrow-asset" : "borrow-pool") : product
    return {
      product,
      slug: row.slug,
      changes: buildParameterChangelog({ slug: row.slug, product: generatorProduct, anchors: row.parameters }),
      updatedAt,
    }
  })
}

export function buildParameterChangeRows(input: {
  borrow: RiskParamRow[]
  lend: RiskParamRow[]
  multiply: RiskParamRow[]
  updatedAt: number
}): SeedParameterChangeRow[] {
  return [
    ...rowsFor("borrow", input.borrow, input.updatedAt),
    ...rowsFor("lend", input.lend, input.updatedAt),
    ...rowsFor("multiply", input.multiply, input.updatedAt),
  ]
}
