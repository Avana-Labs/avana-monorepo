import { describe, expect, it } from "vitest"
import { applyMultiplyAction, assertMultiplySystemInvariants } from "@/app/lib/multiply-engine"
import { makeExampleMultiplySystemState } from "./fixtures"

const POSITION_ID = "wallet-1:eth-usdt"

describe("applyMultiplyAction close", () => {
  it("removes the position and returns borrow capacity to the market", () => {
    const state = makeExampleMultiplySystemState()
    const position = state.positions[POSITION_ID]!
    const marketId = position.marketId
    const liquidityBefore = state.markets[marketId]!.economics.availableLiquidityUsd

    const next = applyMultiplyAction(state, {
      type: "close",
      walletId: "wallet-1",
      positionId: POSITION_ID,
    })

    expect(next.positions[POSITION_ID]).toBeUndefined()
    expect(Object.keys(next.positions)).toHaveLength(0)
    // Repaid debt frees the same amount of borrow liquidity back to the market.
    expect(next.markets[marketId]!.economics.availableLiquidityUsd).toBeCloseTo(
      liquidityBefore + position.debtValueUsd,
      6,
    )

    const tx = next.transactions.at(-1)!
    expect(tx.kind).toBe("close")
    expect(tx.marketId).toBe(marketId)
    expect(tx.multiplierAfter).toBe(1)
    expect(tx.debtDeltaUsd).toBeCloseTo(-position.debtValueUsd, 6)
    // Withdrawn amount is the reclaimed equity (collateral minus repaid debt).
    expect(tx.collateralAmountUsd).toBeCloseTo(position.collateralValueUsd - position.debtValueUsd, 6)

    assertMultiplySystemInvariants(next)
  })

  it("closes a fully-unwound 1.0x/$0 zombie position that deleverage can no longer touch", () => {
    const state = makeExampleMultiplySystemState()
    // Reduce the seeded position to the orphan state: 1.0x, no debt.
    const zombie = state.positions[POSITION_ID]!
    zombie.debtValueUsd = 0
    zombie.multiplier = 1
    zombie.ltv = 0
    zombie.healthFactor = "infinity"

    const next = applyMultiplyAction(state, {
      type: "close",
      walletId: "wallet-1",
      positionId: POSITION_ID,
    })

    expect(next.positions[POSITION_ID]).toBeUndefined()
    const tx = next.transactions.at(-1)!
    expect(tx.kind).toBe("close")
    expect(tx.debtDeltaUsd).toBe(-0)
    assertMultiplySystemInvariants(next)
  })

  it("throws for an unknown position", () => {
    const state = makeExampleMultiplySystemState()
    expect(() =>
      applyMultiplyAction(state, { type: "close", walletId: "wallet-1", positionId: "wallet-1:missing" }),
    ).toThrow(/Unknown position/)
  })
})
