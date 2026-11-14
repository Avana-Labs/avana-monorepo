import { describe, expect, it } from "vitest"
import { BORROW_ASSETS_SEED_ROWS } from "../inputs/borrow-assets-seed"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"

const registryRows = listSpokeBorrowables()
const registryById = new Map(registryRows.map((row) => [row.id, row]))
const seedById = new Map(BORROW_ASSETS_SEED_ROWS.map((row) => [row.id, row]))

describe("borrow assets seed parity", () => {
  it("has one seed row per spoke-borrowable in the registry (71 rows)", () => {
    expect(BORROW_ASSETS_SEED_ROWS.length).toBe(registryRows.length)
    expect(BORROW_ASSETS_SEED_ROWS.length).toBe(71)
    // No duplicate ids on either side.
    expect(seedById.size).toBe(BORROW_ASSETS_SEED_ROWS.length)
    expect(registryById.size).toBe(registryRows.length)
    // Every registry id shows up in the seed, and vice versa.
    for (const registryRow of registryRows) {
      expect(seedById.has(registryRow.id), `missing seed row for ${registryRow.id}`).toBe(true)
    }
    for (const seedRow of BORROW_ASSETS_SEED_ROWS) {
      expect(registryById.has(seedRow.id), `unexpected seed row ${seedRow.id}`).toBe(true)
    }
  })

  it("shapes every id as `${spokeId}:${baseAssetId}`", () => {
    for (const row of BORROW_ASSETS_SEED_ROWS) {
      expect(row.id).toBe(`${row.spokeId}:${row.baseAssetId}`)
      expect(row.id).toMatch(/^[a-z0-9-]+:[a-z0-9-]+$/)
    }
  })

  it("matches numeric + market fields with the registry row-by-row", () => {
    for (const seedRow of BORROW_ASSETS_SEED_ROWS) {
      const registryRow = registryById.get(seedRow.id)
      expect(registryRow, `no registry row for ${seedRow.id}`).toBeDefined()
      if (!registryRow) continue
      expect(seedRow.baseBorrowAprPct).toBe(registryRow.borrowApr)
      // The seed derives totalCapacityUsd from registry.availableUsd (roundUsd is
      // idempotent), and availableUsd carries through unchanged.
      expect(seedRow.totalCapacityUsd).toBe(registryRow.availableUsd)
      expect(seedRow.availableUsd).toBe(registryRow.availableUsd)
      expect(seedRow.utilizationPct).toBe(registryRow.utilization)
      expect(seedRow.totalBorrowedUsd).toBe(registryRow.totalBorrowedUsd)
      expect(seedRow.marketIds).toEqual(registryRow.marketIds)
    }
  })

  it("matches display fields (name, symbol, subtitle, category, contextLabel, displayVisual.symbol)", () => {
    for (const seedRow of BORROW_ASSETS_SEED_ROWS) {
      const registryRow = registryById.get(seedRow.id)
      expect(registryRow, `no registry row for ${seedRow.id}`).toBeDefined()
      if (!registryRow) continue
      expect(seedRow.name).toBe(registryRow.name)
      expect(seedRow.symbol).toBe(registryRow.symbol)
      expect(seedRow.subtitle).toBe(registryRow.subtitle)
      expect(seedRow.category).toBe(registryRow.category)
      expect(seedRow.contextLabel).toBe(registryRow.contextLabel)
      expect(seedRow.displayVisual.symbol).toBe(registryRow.visual.symbol)
    }
  })
})
