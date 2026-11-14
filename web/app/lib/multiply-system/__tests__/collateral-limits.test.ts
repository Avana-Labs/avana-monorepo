import { describe, expect, it } from "vitest"
import {
  buildMultiplyOverCapPreviewUi,
  exceedsMultiplyCollateralCap,
  maxMultiplyCollateralAmount,
  multiplyOverCapReason,
  resolveMultiplyCollateralPriceUsd,
} from "@/app/lib/multiply-system/collateral-limits"

describe("multiply collateral limits", () => {
  it("derives the max collateral amount from market liquidity and price", () => {
    expect(maxMultiplyCollateralAmount(8_400_000, 280)).toBe(30_000)
    expect(maxMultiplyCollateralAmount(5_000_000, 2_500)).toBe(2_000)
  })

  it("caps the max by the wallet balance when it is the smaller constraint", () => {
    // $12,500 wallet against a deep pool → Max is the wallet's affordable amount,
    // not the pool's multi-million liquidity (30,000 tokens).
    expect(maxMultiplyCollateralAmount(8_400_000, 280, 12_500)).toBeCloseTo(12_500 / 280, 6)
    // A shallow pool still binds when it is smaller than the wallet balance.
    expect(maxMultiplyCollateralAmount(1_400, 280, 12_500)).toBeCloseTo(1_400 / 280, 6)
  })

  it("treats zero wallet balance as a zero cap, not an unknown cap", () => {
    const max = maxMultiplyCollateralAmount(8_400_000, 280, 0)
    expect(max).toBe(0)
    expect(exceedsMultiplyCollateralCap(1, max)).toBe(true)
  })

  it("returns null when liquidity or price is missing or non-finite", () => {
    expect(maxMultiplyCollateralAmount(0, 280)).toBeNull()
    expect(maxMultiplyCollateralAmount(8_400_000, 0)).toBeNull()
    expect(maxMultiplyCollateralAmount(Number.NaN, 280)).toBeNull()
    expect(maxMultiplyCollateralAmount(8_400_000, Number.POSITIVE_INFINITY)).toBeNull()
  })

  it("flags amounts over the cap and absurd/non-finite magnitudes", () => {
    const max = maxMultiplyCollateralAmount(8_400_000, 280)! // 30,000
    expect(exceedsMultiplyCollateralCap(999_999_999, max)).toBe(true)
    expect(exceedsMultiplyCollateralCap(30_001, max)).toBe(true)
    expect(exceedsMultiplyCollateralCap(30_000, max)).toBe(false)
    expect(exceedsMultiplyCollateralCap(1, max)).toBe(false)
    expect(exceedsMultiplyCollateralCap(Number.POSITIVE_INFINITY, max)).toBe(true)
  })

  it("never blocks when no cap is known", () => {
    expect(exceedsMultiplyCollateralCap(999_999_999, null)).toBe(false)
  })

  it("E5: values collateral at the live price only when it is a usable positive number", () => {
    // Healthy oracle reading wins.
    expect(resolveMultiplyCollateralPriceUsd(86.08, 105)).toBe(86.08)
    // A 0 / NaN / negative oracle reading falls back to the catalog price so the displayed
    // collateral USD matches the engine-valued exposure instead of collapsing to $0.
    expect(resolveMultiplyCollateralPriceUsd(0, 105)).toBe(105)
    expect(resolveMultiplyCollateralPriceUsd(Number.NaN, 105)).toBe(105)
    expect(resolveMultiplyCollateralPriceUsd(-1, 105)).toBe(105)
    expect(resolveMultiplyCollateralPriceUsd(undefined, 105)).toBe(105)
  })

  it("builds a blocked preview with a clear over-cap reason", () => {
    const ui = buildMultiplyOverCapPreviewUi({
      collateralSymbol: "ETH",
      borrowSymbol: "USDT",
      collateralAmount: 999_999_999,
      collateralPriceUsd: 2_500,
      marketLabel: "ETH · USDT",
      multiplier: 3,
      maxCollateralAmount: 2_000,
    })

    expect(ui.allowed).toBe(false)
    expect(ui.blockedReason).toBe(multiplyOverCapReason("ETH", 2_000))
    expect(ui.blockedReason).toContain("exceeds your available balance")
    expect(ui.validationErrors[0]).toBe(ui.blockedReason)
    expect(ui.metrics).toEqual([])
    expect(ui.balanceLabel).toBe("Balance")
  })
})
