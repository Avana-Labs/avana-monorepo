import { describe, expect, it } from "vitest"
import { parseFixed, formatFixed } from "@/app/lib/credit-engine"
import { applyBorrowLiquidityDeltasToEngineState } from "@/app/lib/market-liquidity/apply"
import { makeExampleBorrowSystemState } from "@/app/lib/credit-engine/__tests__/fixtures"
import { EXAMPLE_UNI_MARKET_ID, EXAMPLE_UNI_USDC_ASSET_ID } from "@/app/lib/credit-engine/__tests__/fixtures"
import { simulateBorrow } from "@/app/lib/credit-engine/simulation"

describe("credit-engine borrow liquidity deltas", () => {
  it("p1-11: folds borrowed deltas into availableLiquidityUsd6 before simulateBorrow", () => {
    const state = makeExampleBorrowSystemState()
    const borrowAmount = parseFixed("1200", 6)

    const withoutDeltas = simulateBorrow(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: borrowAmount,
    })
    expect(withoutDeltas.allowed).toBe(true)

    const deltas = new Map([[EXAMPLE_UNI_USDC_ASSET_ID, { borrowedDeltaUsd: 124_999_000, suppliedDeltaUsd: 0 }]])
    const adjusted = applyBorrowLiquidityDeltasToEngineState(state, deltas)
    const availableAfterDelta = adjusted.assets[EXAMPLE_UNI_USDC_ASSET_ID]!.snapshot.availableLiquidityUsd6
    expect(availableAfterDelta).toBe(parseFixed("1000", 6))

    const withDeltas = simulateBorrow(adjusted, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: borrowAmount,
    })
    expect(withDeltas.allowed).toBe(false)
    expect(withDeltas.validationErrors[0]).toMatch(/liquidity/i)
    expect(formatFixed(availableAfterDelta, 6)).toBe("1000")
  })
})
