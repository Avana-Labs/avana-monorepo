import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG, getSpokeById } from "@/app/lib/borrow-sim"
import { buildPoolDetail } from "@/app/lib/borrow-detail/pool.mock"

describe("pool detail collateral factor single-sources the pool LTV", () => {
  it("renders Risk Parameters collateral factor from row.ltv, matching the list and action page", () => {
    // Guard: at least one pool's collateral factor differs from its spoke max, so the
    // detail page could previously show a value the list never does.
    const divergent = BORROW_POOL_CATALOG.find((row) => row.ltv !== getSpokeById(row.spoke).maxLtv)
    expect(divergent).toBeDefined()

    for (const row of BORROW_POOL_CATALOG) {
      const detail = buildPoolDetail(row)
      const collateralFactor = detail.about.governanceParameters?.parameters.find(
        (parameter) => parameter.id === "collateralFactor",
      )
      expect(collateralFactor?.value).toBe(`${row.ltv.toFixed(2)}%`)
    }
  })
})
