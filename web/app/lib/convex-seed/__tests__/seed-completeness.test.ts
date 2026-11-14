import { describe, expect, it } from "vitest"
import { buildBorrowSeed, type SeedMarketRow } from "@/app/lib/convex-seed/build-seed"

/**
 * Seed-completeness guard.
 *
 * Every market-hydration merge (`mergeConvex*Snapshots` in borrow/lend/multiply
 * market-hydration.ts) silently falls back to the catalog when a snapshot omits an
 * expected field, and emits a dev-only `warnLiveFallback(...)`. In production that
 * degrade is invisible: a market renders a STALE catalog value (this is how the
 * stale `maxLtvPct` shipped) and nothing fails.
 *
 * This test asserts the seed carries every field each merge expects, per scope, so
 * `warnLiveFallback` can never fire against seeded data. The matrix below is the
 * mirror image of the `warnLiveFallback(...)` call sites — keep them in lockstep:
 * when a merge starts reading a new field, add it here.
 */

const ASOF = Date.UTC(2026, 5, 19) // fixed for reproducibility (matches build-seed.test.ts)

/** Fields whose absence makes a merge warn + fall back to catalog, keyed by scope. */
const REQUIRED_STRING_FIELDS: Record<SeedMarketRow["scope"], Array<"name" | "symbol">> = {
  pool: ["name"], // borrow pool merge warns on: name (symbol not read for pools)
  asset: ["name", "symbol"], // borrow asset merge warns on: name, symbol
  lend: ["name", "symbol"], // lend merge warns on: name, symbol
  multiply: ["name", "symbol"], // multiply merge warns on: name, symbol
}

/** Numeric fields required by each merge (guarded as `!== undefined && Number.isFinite`). */
const REQUIRED_NUMBER_FIELDS: Record<
  SeedMarketRow["scope"],
  Array<"maxLtvPct" | "reserveFactorPct" | "rewardsApyPct">
> = {
  pool: ["maxLtvPct", "reserveFactorPct"],
  asset: ["reserveFactorPct"],
  lend: ["reserveFactorPct", "rewardsApyPct"],
  multiply: ["maxLtvPct", "reserveFactorPct"],
}

/** Mirrors the merge guard `field?.trim()` — a present, non-blank string. */
function hasString(value: string | undefined): boolean {
  return typeof value === "string" && value.trim().length > 0
}

/** Mirrors the merge guard `field !== undefined && Number.isFinite(field)`. */
function hasNumber(value: number | undefined): boolean {
  return value !== undefined && Number.isFinite(value)
}

describe("seed completeness (no silent catalog fallback in production)", () => {
  it("every seeded market carries the fields its hydration merge expects", () => {
    const seed = buildBorrowSeed({ days: 1, asOf: ASOF })

    const violations: string[] = []
    for (const market of seed.markets) {
      for (const field of REQUIRED_STRING_FIELDS[market.scope]) {
        if (!hasString(market[field])) {
          violations.push(`${market.scope} "${market.slug}" is missing "${field}"`)
        }
      }
      for (const field of REQUIRED_NUMBER_FIELDS[market.scope]) {
        if (!hasNumber(market[field])) {
          violations.push(`${market.scope} "${market.slug}" is missing "${field}"`)
        }
      }
    }

    // Empty on green; a failure prints the exact slug/field a merge would fall back on.
    expect(violations).toEqual([])
  })
})
