import { describe, expect, it } from "vitest"

import { ABOUT_CONTRACT_ADDRESS_SALTS } from "@/app/lib/detail-page/about-contract-addresses"
import {
  ASSET_CONTRACT_SEED_ROWS,
  LEND_CONTRACT_SEED_ROWS,
  MULTIPLY_CONTRACT_SEED_ROWS,
  POOL_CONTRACT_SEED_ROWS,
} from "../inputs/contract-addresses-seed"

/**
 * The `contractAddressFor` used inside contract-addresses-seed.ts and
 * pool.mock.ts is a file-private function, so this parity test inlines a
 * byte-identical copy of the FNV-1a algorithm documented in both:
 *   - app/lib/borrow-detail/pool.mock.ts (`contractAddressFor`)
 *   - app/lib/convex-seed/build-seed.ts (`contractAddressForSeed`)
 * If the algorithm ever changes, this test catches the drift.
 */
function contractAddressFor(slug: string, salt: string): string {
  const seed = `${slug}:${salt}`
  let hash = 0x811c9dc5
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  const chunk = (hash >>> 0).toString(16).padStart(8, "0").toUpperCase()
  return `0x${chunk}${chunk}${chunk}${chunk}${chunk}`.slice(0, 42)
}

function shortAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

const DETAIL_SALTS = [...ABOUT_CONTRACT_ADDRESS_SALTS]

describe("POOL_CONTRACT_SEED_ROWS parity", () => {
  it("has 320 rows (80 pools × 4 salts)", () => {
    expect(POOL_CONTRACT_SEED_ROWS.length).toBe(320)
  })

  it("emits exactly the pool salt set per unique slug", () => {
    const bySlug = new Map<string, string[]>()
    for (const row of POOL_CONTRACT_SEED_ROWS) {
      const salts = bySlug.get(row.slug) ?? []
      salts.push(row.salt)
      bySlug.set(row.slug, salts)
    }
    // 80 distinct pool slugs, each with the exact 4-salt set.
    expect(bySlug.size).toBe(80)
    for (const [slug, salts] of bySlug.entries()) {
      expect(salts, `slug ${slug} salt set`).toEqual(DETAIL_SALTS)
    }
  })
})

describe("ASSET_CONTRACT_SEED_ROWS parity", () => {
  it("has 284 rows (71 assets × 4 salts)", () => {
    expect(ASSET_CONTRACT_SEED_ROWS.length).toBe(284)
  })

  it("emits exactly the asset salt set per unique slug", () => {
    const bySlug = new Map<string, string[]>()
    for (const row of ASSET_CONTRACT_SEED_ROWS) {
      const salts = bySlug.get(row.slug) ?? []
      salts.push(row.salt)
      bySlug.set(row.slug, salts)
    }
    expect(bySlug.size).toBe(71)
    for (const [slug, salts] of bySlug.entries()) {
      expect(salts, `slug ${slug} salt set`).toEqual(DETAIL_SALTS)
    }
  })
})

describe("MULTIPLY_CONTRACT_SEED_ROWS parity", () => {
  it("has 80 rows (20 markets × 4 salts)", () => {
    expect(MULTIPLY_CONTRACT_SEED_ROWS.length).toBe(80)
  })

  it("emits exactly the multiply salt set per unique slug", () => {
    const bySlug = new Map<string, string[]>()
    for (const row of MULTIPLY_CONTRACT_SEED_ROWS) {
      const salts = bySlug.get(row.slug) ?? []
      salts.push(row.salt)
      bySlug.set(row.slug, salts)
    }
    expect(bySlug.size).toBe(20)
    for (const [slug, salts] of bySlug.entries()) {
      expect(salts, `slug ${slug} salt set`).toEqual(DETAIL_SALTS)
    }
  })
})

describe("LEND_CONTRACT_SEED_ROWS parity", () => {
  it("has 124 rows (31 markets × 4 salts)", () => {
    expect(LEND_CONTRACT_SEED_ROWS.length).toBe(124)
  })

  it("emits exactly the lend salt set per unique slug", () => {
    const bySlug = new Map<string, string[]>()
    for (const row of LEND_CONTRACT_SEED_ROWS) {
      const salts = bySlug.get(row.slug) ?? []
      salts.push(row.salt)
      bySlug.set(row.slug, salts)
    }
    expect(bySlug.size).toBe(31)
    for (const [slug, salts] of bySlug.entries()) {
      expect(salts, `slug ${slug} salt set`).toEqual(DETAIL_SALTS)
    }
  })
})

describe("address hashing parity (spot check)", () => {
  // Pick rows spanning all four seed sets. The hash algorithm is deterministic,
  // so a handful of rows catches any drift in the formula.
  const spotChecks = [
    POOL_CONTRACT_SEED_ROWS[0]!,
    POOL_CONTRACT_SEED_ROWS[Math.floor(POOL_CONTRACT_SEED_ROWS.length / 2)]!,
    ASSET_CONTRACT_SEED_ROWS[0]!,
    ASSET_CONTRACT_SEED_ROWS[ASSET_CONTRACT_SEED_ROWS.length - 1]!,
    LEND_CONTRACT_SEED_ROWS[0]!,
    MULTIPLY_CONTRACT_SEED_ROWS[0]!,
  ]

  for (const [index, row] of spotChecks.entries()) {
    it(`row #${index} (${row.slug}:${row.salt}) matches contractAddressFor + label + href`, () => {
      const expectedAddress = contractAddressFor(row.slug, row.salt)
      expect(row.address).toBe(expectedAddress)
      expect(row.label).toBe(`${expectedAddress.slice(0, 6)}...${expectedAddress.slice(-4)}`)
      expect(row.label).toBe(shortAddress(expectedAddress))
      expect(row.href).toBe(`https://etherscan.io/address/${expectedAddress}`)
      expect(row.isSynthetic).toBe(true)
    })
  }
})
