import { describe, expect, it } from "vitest"
import { revalueMultiplyPosition, simulateMultiply } from "@/app/lib/multiply-engine"
import type { MultiplyPosition } from "@/app/lib/multiply-engine"
import { EXAMPLE_ETH_USDT_MARKET } from "./fixtures"

const market = EXAMPLE_ETH_USDT_MARKET
const basePriceUsd = market.collateralAsset.priceUsd

function makeLeveragedPosition(): MultiplyPosition {
  // A 2x ETH/USDT position valued at the seed price. Only collateralAmount (token
  // qty) and debtValueUsd are the stored primitives; the rest are stale-by-design so
  // we can prove revalue recomputes them.
  const collateralAmount = 2
  const debtValueUsd = collateralAmount * basePriceUsd * 0.5
  return {
    id: "wallet-1:eth-usdt",
    walletId: "wallet-1",
    marketId: market.id,
    collateralAmount,
    // Deliberately WRONG frozen values (a price ago): revalue must overwrite these.
    collateralValueUsd: 1,
    debtValueUsd,
    multiplier: 2,
    ltv: 999,
    healthFactor: 0.01,
    liquidationPrice: 999_999,
    netApy: 0.03,
    openedAt: 0,
    lastUpdatedAt: 0,
  }
}

describe("revalueMultiplyPosition", () => {
  it("derives collateralValueUsd = collateralAmount * current price (not the frozen value)", () => {
    const position = makeLeveragedPosition()
    const revalued = revalueMultiplyPosition(position, market)

    expect(revalued.collateralValueUsd).toBeCloseTo(position.collateralAmount * basePriceUsd, 6)
    // Stored primitives are preserved.
    expect(revalued.collateralAmount).toBe(position.collateralAmount)
    expect(revalued.debtValueUsd).toBe(position.debtValueUsd)
  })

  it("derives HF with the SAME engine math as a live simulation", () => {
    // Fresh position (no existing) so its `after` is the canonical simulated state.
    const collateralAmount = 1
    const simulation = simulateMultiply({
      market,
      collateralAmount,
      selectedMultiplier: 2,
    })

    // Rebuild a stored position from the simulation's primitives, then revalue at the
    // same price. The derived HF/collateralValueUsd/liquidationPrice must match.
    const stored: MultiplyPosition = {
      id: "wallet-1:eth-usdt",
      walletId: "wallet-1",
      marketId: market.id,
      collateralAmount: simulation.after.collateralAmount,
      collateralValueUsd: 0,
      debtValueUsd: simulation.after.debtValueUsd,
      multiplier: simulation.after.multiplier,
      ltv: 0,
      healthFactor: "infinity",
      liquidationPrice: null,
      netApy: 0,
      openedAt: 0,
      lastUpdatedAt: 0,
    }
    const revalued = revalueMultiplyPosition(stored, market)

    expect(revalued.collateralValueUsd).toBeCloseTo(simulation.after.collateralValueUsd, 6)
    expect(revalued.healthFactor).not.toBe("infinity")
    expect(revalued.healthFactor as number).toBeCloseTo(simulation.after.healthFactor as number, 6)
    expect(revalued.liquidationPrice as number).toBeCloseTo(simulation.after.liquidationPrice as number, 6)
    expect(revalued.ltv).toBeCloseTo(simulation.after.ltv, 6)
  })

  it("is not frozen: a higher price raises collateralValueUsd and HF, a lower price lowers HF", () => {
    const position = makeLeveragedPosition()

    const atSeed = revalueMultiplyPosition(position, market, basePriceUsd)
    const atHigher = revalueMultiplyPosition(position, market, basePriceUsd * 1.2)
    const atLower = revalueMultiplyPosition(position, market, basePriceUsd * 0.8)

    // collateralValueUsd tracks the price.
    expect(atHigher.collateralValueUsd).toBeGreaterThan(atSeed.collateralValueUsd)
    expect(atLower.collateralValueUsd).toBeLessThan(atSeed.collateralValueUsd)

    // HF is finite (there is debt) and rises with price / falls with price.
    const hf = (p: MultiplyPosition) => p.healthFactor as number
    expect(hf(atSeed)).toBeGreaterThan(0)
    expect(hf(atHigher)).toBeGreaterThan(hf(atSeed))
    expect(hf(atLower)).toBeLessThan(hf(atSeed))
  })

  it("falls back to the market price when the override is non-finite or non-positive", () => {
    const position = makeLeveragedPosition()
    const expected = position.collateralAmount * basePriceUsd

    expect(revalueMultiplyPosition(position, market, 0).collateralValueUsd).toBeCloseTo(expected, 6)
    expect(revalueMultiplyPosition(position, market, -5).collateralValueUsd).toBeCloseTo(expected, 6)
    expect(revalueMultiplyPosition(position, market, Number.NaN).collateralValueUsd).toBeCloseTo(expected, 6)
  })
})
