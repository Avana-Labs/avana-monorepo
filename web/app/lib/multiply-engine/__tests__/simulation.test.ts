import { describe, expect, it } from "vitest"
import { simulateDeleverage, simulateMultiply } from "@/app/lib/multiply-engine"
import { EXAMPLE_ETH_USDT_MARKET, makeExampleMultiplySystemState } from "./fixtures"

describe("multiply engine simulation", () => {
  it("simulates multiply with validation output", () => {
    const simulation = simulateMultiply({
      market: EXAMPLE_ETH_USDT_MARKET,
      collateralAmount: 1,
      selectedMultiplier: 2,
    })

    expect(simulation.action).toBe("multiply")
    expect(simulation.after.collateralValueUsd).toBeGreaterThan(simulation.before.collateralValueUsd)
    expect(simulation.after.debtValueUsd).toBeGreaterThan(0)
    expect(simulation.validation.allowed).toBe(true)
  })

  it("keeps token input and leverage on Aave-style scales", () => {
    const collateralAmount = 0.01
    const selectedMultiplier = 2
    const inputEquityUsd = collateralAmount * EXAMPLE_ETH_USDT_MARKET.collateralAsset.priceUsd
    const simulation = simulateMultiply({
      market: EXAMPLE_ETH_USDT_MARKET,
      collateralAmount,
      selectedMultiplier,
    })

    // Price-relative so this survives baseline-price changes: 0.01 ETH at the single
    // sandbox baseline (~$1,934) is the equity; leverage math is asserted against it.
    expect(inputEquityUsd).toBeCloseTo(19.34, 2)
    expect(simulation.after.collateralValueUsd).toBeGreaterThan(inputEquityUsd * 1.9)
    expect(simulation.after.collateralValueUsd).toBeLessThanOrEqual(inputEquityUsd * selectedMultiplier)
    expect(simulation.after.debtValueUsd).toBeGreaterThan(inputEquityUsd * 0.9)
    expect(simulation.after.debtValueUsd).toBeLessThan(inputEquityUsd)
    expect(simulation.after.multiplier).toBeCloseTo(selectedMultiplier, 6)
  })

  it("reduces health and remaining borrow capacity as leverage rises", () => {
    const low = simulateMultiply({
      market: EXAMPLE_ETH_USDT_MARKET,
      collateralAmount: 0.01,
      selectedMultiplier: 1.5,
    })
    const high = simulateMultiply({
      market: EXAMPLE_ETH_USDT_MARKET,
      collateralAmount: 0.01,
      selectedMultiplier: 2.2,
    })
    const capacity = (simulation: typeof low) =>
      simulation.after.collateralValueUsd * EXAMPLE_ETH_USDT_MARKET.risk.maxLtv - simulation.after.debtValueUsd

    expect(high.after.healthFactor).not.toBe("infinity")
    expect(low.after.healthFactor).not.toBe("infinity")
    expect(high.after.healthFactor as number).toBeLessThan(low.after.healthFactor as number)
    expect(capacity(high)).toBeLessThan(capacity(low))
  })

  it("adds new multiply exposure to an existing same-market position", () => {
    const state = makeExampleMultiplySystemState()
    const position = Object.values(state.positions).find((item) => item.marketId === EXAMPLE_ETH_USDT_MARKET.id)!

    const simulation = simulateMultiply({
      market: EXAMPLE_ETH_USDT_MARKET,
      collateralAmount: 0.5,
      selectedMultiplier: 2,
      existingPosition: position,
    })

    expect(simulation.validation.allowed).toBe(true)
    expect(simulation.before.collateralValueUsd).toBe(position.collateralValueUsd)
    expect(simulation.after.collateralValueUsd).toBeGreaterThan(position.collateralValueUsd)
    expect(simulation.after.debtValueUsd).toBeGreaterThan(position.debtValueUsd)
    expect(simulation.after.multiplier).toBeCloseTo(
      simulation.after.collateralValueUsd / (simulation.after.collateralValueUsd - simulation.after.debtValueUsd),
      5,
    )
  })

  it("simulates deleverage and improves health factor", () => {
    const state = makeExampleMultiplySystemState()
    const position = Object.values(state.positions)[0]!
    const market = state.markets[position.marketId]!

    const simulation = simulateDeleverage({
      market,
      position,
      targetMultiplier: 1.8,
    })

    expect(simulation.validation.allowed).toBe(true)
    expect(simulation.after.debtValueUsd).toBeLessThan(simulation.before.debtValueUsd)
    if (simulation.before.healthFactor !== "infinity" && simulation.after.healthFactor !== "infinity") {
      expect(simulation.after.healthFactor).toBeGreaterThanOrEqual(simulation.before.healthFactor)
    }
  })

  it("fully deleverages by selling collateral instead of minting equity", () => {
    const state = makeExampleMultiplySystemState()
    const position = Object.values(state.positions)[0]!
    const market = state.markets[position.marketId]!

    const simulation = simulateDeleverage({
      market,
      position,
      targetMultiplier: 1,
    })

    expect(simulation.validation.allowed).toBe(true)
    expect(simulation.after.debtValueUsd).toBe(0)
    expect(simulation.after.collateralValueUsd).toBeLessThan(simulation.before.collateralValueUsd)
    expect(simulation.after.multiplier).toBe(1)
    expect(simulation.after.ltv).toBe(0)
    // Full deleverage cannot increase user equity: collateral is sold at swap efficiency.
    expect(simulation.after.collateralValueUsd).toBeLessThanOrEqual(
      simulation.before.collateralValueUsd - simulation.before.debtValueUsd,
    )
  })
})
