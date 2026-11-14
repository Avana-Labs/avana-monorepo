/**
 * Engine input guards: the multiply and lend engines must reject non-finite or
 * degenerate numeric inputs at the boundary instead of persisting NaN/Infinity
 * (or zero/negative collateral) into state.
 */
import { describe, expect, it } from "vitest"

import { applyMultiplyAction } from "@/app/lib/multiply-engine"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"

import { applyLendAction } from "@/app/lib/lend-system/model"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"

const MULTIPLY_MARKET = "eth-usdt"
const LEND_MARKET = "eth"
const ids = { positionId: "p1", transactionId: "t1" }

describe("multiply engine input guards", () => {
  const badAmounts = [Number.NaN, Number.POSITIVE_INFINITY, 0, -1]
  const badMultipliers = [Number.NaN, Number.POSITIVE_INFINITY, 0, 0.5]

  it.each(badAmounts)("rejects collateralAmount=%s", (collateralAmount) => {
    const state = buildMockMultiplySystemState("guard")
    expect(() =>
      applyMultiplyAction(state, {
        type: "multiply",
        walletId: "guard",
        marketId: MULTIPLY_MARKET,
        collateralAmount,
        selectedMultiplier: 2,
      }),
    ).toThrow()
  })

  it.each(badMultipliers)("rejects selectedMultiplier=%s", (selectedMultiplier) => {
    const state = buildMockMultiplySystemState("guard")
    expect(() =>
      applyMultiplyAction(state, {
        type: "multiply",
        walletId: "guard",
        marketId: MULTIPLY_MARKET,
        collateralAmount: 1,
        selectedMultiplier,
      }),
    ).toThrow()
  })

  it("rejects non-finite deleverage target", () => {
    const state = buildMockMultiplySystemState("guard")
    expect(() =>
      applyMultiplyAction(state, {
        type: "deleverage",
        walletId: "guard",
        positionId: "guard:eth-usdt",
        targetMultiplier: Number.NaN,
      }),
    ).toThrow()
  })

  it("accepts a well-formed multiply and persists a finite position", () => {
    const state = buildMockMultiplySystemState("guard")
    const next = applyMultiplyAction(state, {
      type: "multiply",
      walletId: "guard",
      marketId: MULTIPLY_MARKET,
      collateralAmount: 1,
      selectedMultiplier: 2,
    })
    const position = next.positions["guard:eth-usdt"]
    expect(position).toBeTruthy()
    expect(Number.isFinite(position!.ltv)).toBe(true)
    expect(Number.isFinite(position!.multiplier)).toBe(true)
    expect(position!.collateralValueUsd).toBeGreaterThan(0)
  })
})

describe("lend engine input guards", () => {
  const badAmounts = [Number.NaN, Number.POSITIVE_INFINITY, 0, -5]

  it.each(badAmounts)("ignores deposit with depositAmount=%s", (depositAmount) => {
    const state = buildMockLendSystemState("guard")
    const next = applyLendAction(
      state,
      { type: "deposit", walletId: "guard", marketId: LEND_MARKET, depositAmount, walletBalance: 1e9 },
      ids,
    )
    expect(next).toBe(state)
  })

  it("ignores withdraw with non-finite amount", () => {
    const state = buildMockLendSystemState("guard")
    const next = applyLendAction(
      state,
      {
        type: "withdraw",
        walletId: "guard",
        marketId: LEND_MARKET,
        positionId: "x",
        withdrawAmount: Number.POSITIVE_INFINITY,
      },
      ids,
    )
    expect(next).toBe(state)
  })

  it("accepts a well-formed deposit", () => {
    const state = buildMockLendSystemState("guard")
    const next = applyLendAction(
      state,
      { type: "deposit", walletId: "guard", marketId: LEND_MARKET, depositAmount: 1, walletBalance: 1e9 },
      ids,
    )
    expect(next).not.toBe(state)
  })
})
