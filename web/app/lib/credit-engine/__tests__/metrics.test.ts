import { describe, expect, it } from "vitest"
import { WAD_DECIMALS, formatFixed, parseFixed } from "@/app/lib/credit-engine"
import {
  calculateBorrowCapacityUsd6,
  calculateCreditMetrics,
  calculateCurrentLtvWad,
  calculateHealthFactorWad,
  calculateSpokeCreditMetrics,
} from "@/app/lib/credit-engine/metrics"
import { EXAMPLE_UNI_MARKET_ID, makeExampleBorrowSystemState } from "./fixtures"

describe("credit metrics", () => {
  it("matches the example borrow account formulas", () => {
    const state = makeExampleBorrowSystemState()
    const metrics = calculateCreditMetrics(state, "wallet-1")
    expect(formatFixed(metrics.poolCollateralValueUsd6, 6)).toBe("20399.225")
    expect(formatFixed(metrics.creditLimitUsd6, 6)).toBe("14480.3956")
    expect(formatFixed(metrics.availableCreditUsd6, 6)).toBe("8280.3956")
    expect(formatFixed(metrics.totalBorrowedUsd6, 6)).toBe("6200")
    expect(formatFixed(metrics.liquidationValueUsd6, 6)).toBe("16520.3181")
    expect(formatFixed(metrics.liquidationBufferUsd6, 6)).toBe("10320.3181")
    expect(formatFixed(metrics.netAccountValueUsd6, 6)).toBe("26699.225")
    expect(formatFixed(metrics.healthFactorWad, WAD_DECIMALS)).toBe("2.664567435483870967")
    expect(formatFixed(metrics.weightedCollateralRiskWad, WAD_DECIMALS)).toBe("0.24283686757707707")
    expect(formatFixed(metrics.riskPremiumWad, WAD_DECIMALS)).toBe("0.022558427640694814")
    expect(formatFixed(metrics.borrowAprWad, WAD_DECIMALS)).toBe("0.074558427640694814")
    expect(formatFixed(metrics.netApyWad, WAD_DECIMALS)).toBe("0.112458389672359403")
    expect(formatFixed(metrics.annualYieldEarnedUsd6, 6)).toBe("3464.8141")
    expect(formatFixed(metrics.annualBorrowCostUsd6, 6)).toBe("462.262251")
  })

  it("clamps available credit at zero", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = debt.principalBorrowedUsd6 * 4n
    debt.debtSharesUsd6 = debt.debtSharesUsd6 * 4n

    const metrics = calculateCreditMetrics(state, "wallet-1")
    expect(metrics.availableCreditUsd6).toBe(0n)
  })

  it("keeps wallet aggregates separate from spoke insolvency", () => {
    const state = makeExampleBorrowSystemState()
    const uniPosition = state.accounts["wallet-1"]!.collateralPositions.find(
      (position) => position.marketId === EXAMPLE_UNI_MARKET_ID,
    )!
    uniPosition.collateralShares = parseFixed("4", 18)
    uniPosition.principalTokenAmount = parseFixed("4", 18)

    const walletMetrics = calculateCreditMetrics(state, "wallet-1")
    const spokeMetrics = calculateSpokeCreditMetrics(state, "wallet-1", "uni-v3-bluechip")

    expect(walletMetrics.availableCreditUsd6).toBeGreaterThan(0n)
    expect(spokeMetrics.availableCreditUsd6).toBe(0n)
    expect(spokeMetrics.healthFactorWad).toBeLessThan(parseFixed("1", 18))
  })

  it("calculates borrow capacity from collateral factors across enabled collateral positions", () => {
    const state = makeExampleBorrowSystemState()

    expect(formatFixed(calculateBorrowCapacityUsd6(state, "wallet-1"), 6)).toBe("14480.3956")
  })

  it("caps borrow capacity on the collateral factor, NOT the liquidation threshold", () => {
    const state = makeExampleBorrowSystemState()
    const before = calculateBorrowCapacityUsd6(state, "wallet-1")
    const metrics = calculateCreditMetrics(state, "wallet-1")

    // Collateral factor < liquidation threshold, so credit limit must be strictly
    // below the liquidation value. Borrow capacity tracks the credit limit.
    expect(metrics.creditLimitUsd6).toBeLessThan(metrics.liquidationValueUsd6)
    expect(before).toBe(metrics.creditLimitUsd6)

    // Raising ONLY the liquidation threshold must not change borrow capacity —
    // it would only move the liquidation value / health factor.
    for (const market of Object.values(state.markets)) {
      market.riskConfig.liquidationThresholdWad = parseFixed("0.99", 18)
    }
    const after = calculateBorrowCapacityUsd6(state, "wallet-1")
    expect(after).toBe(before)
    expect(calculateCreditMetrics(state, "wallet-1").liquidationValueUsd6).toBeGreaterThan(metrics.liquidationValueUsd6)
  })

  it("never returns borrow capacity above the sum allowed by collateral factors", () => {
    const state = makeExampleBorrowSystemState()
    state.markets["uni-v3-bluechip-weth-usdc"]!.riskConfig.collateralFactorWad = parseFixed("1.25", 18)

    expect(formatFixed(calculateBorrowCapacityUsd6(state, "wallet-1"), 6)).toBe("20399.225")
  })

  it("returns zero borrow capacity when all collateral is invalid or disabled", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = state.accounts["wallet-1"]!.collateralPositions.map(
      (position) => ({
        ...position,
        collateralEnabled: false,
      }),
    )

    expect(calculateBorrowCapacityUsd6(state, "wallet-1")).toBe(0n)
  })

  it("returns zero borrow capacity when collateral value is zero", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = []

    expect(calculateBorrowCapacityUsd6(state, "wallet-1")).toBe(0n)
  })

  it("applies lower borrow capacity for higher-risk volatile pool vs stable pool", () => {
    const state = makeExampleBorrowSystemState()
    const uniCapacity = calculateBorrowCapacityUsd6(state, "wallet-1", "uni-v3-bluechip")
    const curveCapacity = calculateBorrowCapacityUsd6(state, "wallet-1", "curve-crypto")

    expect(uniCapacity).toBeGreaterThan(curveCapacity)
    expect(formatFixed(uniCapacity, 6)).toBe("10960.6068")
    expect(formatFixed(curveCapacity, 6)).toBe("3519.7888")
  })

  it("never allows available credit above borrow capacity minus outstanding debt", () => {
    const state = makeExampleBorrowSystemState()
    const metrics = calculateCreditMetrics(state, "wallet-1")
    const capacity = calculateBorrowCapacityUsd6(state, "wallet-1")

    expect(metrics.availableCreditUsd6).toBeLessThanOrEqual(capacity)
    expect(metrics.availableCreditUsd6).toBe(capacity - metrics.totalBorrowedUsd6)
  })

  it("calculates current ltv from outstanding debt and collateral value", () => {
    const state = makeExampleBorrowSystemState()

    expect(formatFixed(calculateCurrentLtvWad(state, "wallet-1"), WAD_DECIMALS)).toBe("0.303933115106088589")
  })

  it("returns zero ltv when there is no debt", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.debtPositions = []

    expect(calculateCurrentLtvWad(state, "wallet-1")).toBe(0n)
  })

  it("handles zero collateral safely when calculating ltv", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = []

    expect(calculateCurrentLtvWad(state, "wallet-1")).toBe(0n)
  })

  it("returns a safe health factor when there is no debt", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.debtPositions = []

    expect(calculateHealthFactorWad(state, "wallet-1")).toBeNull()
  })

  it("lowers health factor as debt increases", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    const before = calculateHealthFactorWad(state, "wallet-1")

    debt.principalBorrowedUsd6 += parseFixed("1000", 6)
    debt.debtSharesUsd6 += parseFixed("1000", 6)

    const after = calculateHealthFactorWad(state, "wallet-1")
    expect(before).not.toBeNull()
    expect(after).not.toBeNull()
    expect(after!).toBeLessThan(before!)
  })

  it("lowers health factor as collateral value drops and flags unhealthy positions", () => {
    const state = makeExampleBorrowSystemState()
    const account = state.accounts["wallet-1"]!

    const before = calculateHealthFactorWad(state, "wallet-1")
    account.collateralPositions = []

    const after = calculateHealthFactorWad(state, "wallet-1")

    expect(before).not.toBeNull()
    expect(after).not.toBeNull()
    expect(after!).toBeLessThan(before!)
    expect(after!).toBeLessThan(parseFixed("1", 18))
  })

  it("flags unhealthy positions below the 1.0 health factor threshold", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = parseFixed("20000", 6)
    debt.debtSharesUsd6 = parseFixed("20000", 6)

    const healthFactor = calculateHealthFactorWad(state, "wallet-1")
    expect(healthFactor).not.toBeNull()
    expect(healthFactor!).toBeLessThan(parseFixed("1", 18))
  })
})

describe("net APY clamp (C5)", () => {
  it("bounds an exploding near-zero-equity ratio to ±1000%", async () => {
    const { clampNetApyWad, MAX_NET_APY_MAGNITUDE_WAD } = await import("@/app/lib/credit-engine/metrics")
    // $1000 collateral @5%, $999 debt @8%, ~$1 equity would raw out to ≈ -2990%.
    expect(clampNetApyWad(parseFixed("-29.9", 18))).toBe(-MAX_NET_APY_MAGNITUDE_WAD)
    expect(clampNetApyWad(parseFixed("50", 18))).toBe(MAX_NET_APY_MAGNITUDE_WAD)
    // Legitimate values pass through untouched.
    expect(clampNetApyWad(parseFixed("0.1124", 18))).toBe(parseFixed("0.1124", 18))
    expect(clampNetApyWad(parseFixed("-0.5", 18))).toBe(parseFixed("-0.5", 18))
  })
})
