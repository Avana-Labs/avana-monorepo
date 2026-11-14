import { describe, expect, it } from "vitest"
import { applyMultiplyAction } from "@/app/lib/multiply-engine"
import { makeExampleMultiplySystemState } from "./fixtures"

// Prod 2026-09-23: opening 1 AAVE at 1.5x on AAVE/GHO, where the wallet already had a $83,333 2x
// loop hydrated from Convex (keyed by its Convex id), replaced that loop with a $207 position.
describe("applyMultiplyAction on a market with a hydrated loop", () => {
  it("adds to the existing loop instead of replacing it", () => {
    const state = makeExampleMultiplySystemState()
    const seeded = state.positions["wallet-1:eth-usdt"]!
    delete state.positions["wallet-1:eth-usdt"]
    state.positions["kn7convexid"] = { ...seeded, id: "kn7convexid" }

    const next = applyMultiplyAction(state, {
      type: "multiply",
      walletId: "wallet-1",
      marketId: seeded.marketId,
      collateralAmount: 0.1,
      selectedMultiplier: 1.5,
    })

    const loops = Object.values(next.positions).filter((position) => position.marketId === seeded.marketId)
    expect(loops).toHaveLength(1)
    expect(loops[0]!.id).toBe("kn7convexid")
    expect(loops[0]!.collateralValueUsd).toBeGreaterThan(seeded.collateralValueUsd)
    expect(loops[0]!.debtValueUsd).toBeGreaterThanOrEqual(seeded.debtValueUsd)
  })
})
