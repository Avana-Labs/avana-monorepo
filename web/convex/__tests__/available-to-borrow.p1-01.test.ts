import { describe, expect, it } from "vitest"

/**
 * p1-01: ATB must derive from per-pool collateral factors, not a hardcoded *0.7.
 * Source-level guard — the runtime path is covered by sandbox transaction/onboarding
 * integration; this locks the formula out of the hot snapshot writers.
 */
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("availableToBorrowUsd derivation", () => {
  it("p1-01: snapshot writers do not hardcode collateral * 0.7", () => {
    const transactions = readFileSync(resolve(__dirname, "../sandbox/transactions.ts"), "utf8")
    const onboarding = readFileSync(resolve(__dirname, "../sandbox/onboarding.ts"), "utf8")
    expect(transactions).not.toMatch(/borrowCollateral\s*\*\s*0\.7/)
    expect(onboarding).not.toMatch(/collateralValueUsd\s*\*\s*0\.7/)
    expect(transactions).toMatch(/maxLtvPct/)
    expect(onboarding).toMatch(/maxLtvPct/)
  })
})
