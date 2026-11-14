import { describe, expect, it } from "vitest"
import { parseFixed } from "@/app/lib/credit-engine"
import { applyBorrowAction } from "@/app/lib/credit-engine/actions"
import {
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  makeExampleBorrowSystemState,
} from "@/app/lib/credit-engine/__tests__/fixtures"
import { buildBorrowBalanceMetrics } from "@/app/dashboard/dashboard-tab-metrics"

// One dollar of rounding tolerance for share-index arithmetic.
const TOLERANCE = 1

// buildBorrowBalanceMetrics accrues to `now` (defaulting to Date.now()). These
// invariance checks read each state at its OWN settlement index (state.now / next.now)
// so the assertion isolates the ACTION's effect on Net Value, not the interest that
// ticks with wall-clock time between two reads.

describe("credit overview Net Value tracks pledged collateral minus debt", () => {
  it("falls by the new debt when borrowing", () => {
    const state = makeExampleBorrowSystemState()
    const before = buildBorrowBalanceMetrics(state, "wallet-1", state.now).netValueUsd

    const next = applyBorrowAction(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("16", 6),
    })
    const after = buildBorrowBalanceMetrics(next, "wallet-1", next.now).netValueUsd

    expect(before - after).toBeCloseTo(16, 6)
  })

  it("falls when collateral leaves the protocol position", () => {
    const state = makeExampleBorrowSystemState()
    const before = buildBorrowBalanceMetrics(state, "wallet-1", state.now).netValueUsd

    const next = applyBorrowAction(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      amountUsd6: parseFixed("210", 6),
    })
    const after = buildBorrowBalanceMetrics(next, "wallet-1", next.now).netValueUsd

    expect(before - after).toBeCloseTo(210, 6)
  })

  it("excludes a fully removed collateral market from the position value", () => {
    const state = makeExampleBorrowSystemState()
    const before = buildBorrowBalanceMetrics(state, "wallet-1", state.now).netValueUsd

    const next = applyBorrowAction(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:curve-eth-usdt",
      percentBps: 10_000,
    })
    const after = buildBorrowBalanceMetrics(next, "wallet-1", next.now).netValueUsd

    expect(
      next.accounts["wallet-1"]!.collateralPositions.some((position) => position.id === "wallet-1:curve-eth-usdt"),
    ).toBe(false)
    expect(before - after).toBeGreaterThan(TOLERANCE)
    expect(next.accounts["wallet-1"]!.walletReturnedLpBalancesUsd6?.["curve-eth-usdt"]).toBeGreaterThan(0n)
  })

  it("does not drift when re-supplying LP that was first returned from collateral removal", () => {
    const state = makeExampleBorrowSystemState()
    const before = buildBorrowBalanceMetrics(state, "wallet-1", state.now).netValueUsd

    const afterRemove = applyBorrowAction(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      amountUsd6: parseFixed("1000", 6),
    })

    const next = applyBorrowAction(afterRemove, {
      type: "supplyCollateral",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      amountUsd6: parseFixed("1000", 6),
    })
    const after = buildBorrowBalanceMetrics(next, "wallet-1", next.now).netValueUsd

    expect(Math.abs(after - before)).toBeLessThanOrEqual(TOLERANCE)
  })
})
