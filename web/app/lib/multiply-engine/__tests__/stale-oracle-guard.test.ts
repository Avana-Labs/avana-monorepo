import { describe, expect, it } from "vitest"
import { validateMultiplyAction } from "@/app/lib/multiply-engine/validation"

const baseline = {
  selectedMultiplier: 2,
  theoreticalMaxMultiplier: 4,
  publicMaxMultiplier: 5,
  safeMaxMultiplier: 4,
  recommendedMaxMultiplier: 3.5,
  minHealthFactor: 1.3,
  maxLtv: 0.75,
  healthFactor: 2.1 as number | "infinity",
  ltv: 0.4,
  debtValueUsd: 2500,
  initialCollateralValueUsd: 3500,
  priceImpactPct: 0.002,
  maxAllowedPriceImpact: 0.01,
  netApy: 0.03,
  supplyApy: 0.076,
  borrowApy: 0.039,
  liquidationPrice: 1200,
  collateralPriceUsd: 1934,
}

describe("multiply stale-oracle guard (C15)", () => {
  it("allows a leverage open when the oracle price is fresh", () => {
    const result = validateMultiplyAction({ ...baseline, oracleStale: false })
    expect(result.allowed).toBe(true)
  })

  it("blocks a leverage open when the collateral oracle price is stale", () => {
    const result = validateMultiplyAction({ ...baseline, oracleStale: true })
    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toMatch(/stale/i)
  })

  it("is inert when freshness is not provided (backwards compatible)", () => {
    const result = validateMultiplyAction(baseline)
    expect(result.allowed).toBe(true)
  })
})
