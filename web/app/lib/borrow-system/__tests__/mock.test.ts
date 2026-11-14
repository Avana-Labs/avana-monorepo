import { describe, expect, it } from "vitest"
import { assertBorrowSystemInvariants, calculateCreditMetrics } from "@/app/lib/borrow-system/model"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"

describe("mock borrow system source", () => {
  it("builds a canonical borrow system state for the demo wallet", () => {
    const state = buildMockBorrowSystemState("demo-wallet")

    assertBorrowSystemInvariants(state)
    expect(Object.keys(state.markets).length).toBeGreaterThan(3)
    expect(Object.keys(state.assets).length).toBeGreaterThan(5)
    expect(state.accounts["demo-wallet"]?.collateralPositions.length).toBe(3)
    expect(state.accounts["demo-wallet"]?.debtPositions.length).toBe(2)

    const metrics = calculateCreditMetrics(state, "demo-wallet")
    expect(metrics.poolCollateralValueUsd6).toBeGreaterThan(0n)
    expect(metrics.availableCreditUsd6).toBeGreaterThan(0n)
  })

  it("keeps the home workspace wallet free of seeded debt", () => {
    const state = buildMockBorrowSystemState("home-demo-wallet")

    expect(state.accounts["home-demo-wallet"]?.collateralPositions.length).toBe(3)
    expect(state.accounts["home-demo-wallet"]?.debtPositions).toEqual([])
  })
})
