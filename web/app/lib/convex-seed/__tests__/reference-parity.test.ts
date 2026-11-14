import { describe, expect, it } from "vitest"

import { SMART_SPOKES } from "@/app/borrow/components/borrow-workspace"
import { BORROW_DEXES, BORROW_SPOKES } from "@/app/lib/borrow-sim"
import { SPOKE_SLUGS } from "@/app/lib/borrow-system/registry"

import { DEXES_SEED_ROWS, SPOKES_SEED_ROWS } from "../inputs/reference-seed"

/**
 * Byte-for-byte parity between the extracted seed rows and the original mock
 * catalogs they were derived from. A future refactor that edits either side in
 * isolation trips this test — the seed can never silently drift away from what
 * the UI currently renders.
 */

describe("spokes seed matches BORROW_SPOKES", () => {
  it("has the same row count (17)", () => {
    expect(SPOKES_SEED_ROWS.length).toBe(17)
    expect(SPOKES_SEED_ROWS.length).toBe(BORROW_SPOKES.length)
  })

  it("carries the spot-checked numeric fields verbatim from BORROW_SPOKES", () => {
    const sourceById = new Map(BORROW_SPOKES.map((spoke) => [spoke.id, spoke]))
    for (const row of SPOKES_SEED_ROWS) {
      const source = sourceById.get(row.id as (typeof BORROW_SPOKES)[number]["id"])
      expect(source, `no BORROW_SPOKES entry for seed row id="${row.id}"`).toBeDefined()
      expect(row.maxLtvPct).toBe(source!.maxLtv)
      expect(row.aprApproxPct).toBe(source!.aprApprox)
      expect(row.riskPremiumBps).toBe(source!.riskPremiumBps)
      expect(row.liquidityUsd).toBe(source!.liquidityUsd)
    }
  })

  it("resolves each row's slug through SPOKE_SLUGS", () => {
    for (const row of SPOKES_SEED_ROWS) {
      expect(row.slug).toBe(SPOKE_SLUGS[row.id as keyof typeof SPOKE_SLUGS])
    }
  })

  it("mirrors SMART_SPOKES membership via isSmartSpoke", () => {
    for (const row of SPOKES_SEED_ROWS) {
      expect(row.isSmartSpoke).toBe(SMART_SPOKES.has(row.id))
    }
  })
})

describe("dexes seed matches BORROW_DEXES", () => {
  it("has the same row count", () => {
    expect(DEXES_SEED_ROWS.length).toBe(BORROW_DEXES.length)
  })

  it("carries id, label, and tvlUsd verbatim from BORROW_DEXES", () => {
    const sourceById = new Map(BORROW_DEXES.map((dex) => [dex.id, dex]))
    for (const row of DEXES_SEED_ROWS) {
      const source = sourceById.get(row.id as (typeof BORROW_DEXES)[number]["id"])
      expect(source, `no BORROW_DEXES entry for seed row id="${row.id}"`).toBeDefined()
      expect(row.id).toBe(source!.id)
      expect(row.label).toBe(source!.label)
      expect(row.tvlUsd).toBe(source!.tvlUsd)
    }
  })
})
