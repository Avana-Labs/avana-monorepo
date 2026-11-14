import { describe, expect, it } from "vitest"
import {
  applyBorrowActions,
  assertBorrowSystemInvariants,
  calculateCreditMetrics,
  parseFixed,
  simulateBorrow,
  simulateDeposit,
  simulateLiquidation,
  simulateRepay,
  simulateWithdraw,
} from "@/app/lib/credit-engine"
import {
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  EXAMPLE_WALLET_1_DEBT_ID,
  makeExampleBorrowSystemState,
} from "./fixtures"
import { makeStressBorrowActions, makeStressBorrowSystemState } from "./stress-fixtures"

describe("borrow engine multi-user simulation", () => {
  it("keeps 1000 wallet interactions consistent across a large action batch", { timeout: 60_000 }, () => {
    const state = makeStressBorrowSystemState(1000)
    const actions = makeStressBorrowActions(state)
    const next = applyBorrowActions(state, actions)

    expect(Object.keys(next.accounts)).toHaveLength(1000)
    expect(next.transactions).toHaveLength(actions.length)
    assertBorrowSystemInvariants(next)

    for (const walletId of Object.keys(next.accounts)) {
      const metrics = calculateCreditMetrics(next, walletId)
      expect(metrics.poolCollateralValueUsd6).toBeGreaterThan(parseFixed("1000", 6))
      expect(metrics.totalBorrowedUsd6).toBeGreaterThanOrEqual(0n)
      expect(metrics.availableCreditUsd6).toBeGreaterThanOrEqual(0n)
      expect(metrics.healthFactorWad).toBeGreaterThan(parseFixed("1", 18))
    }
  })

  it("simulates deposit with before/after state and preserved health", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateDeposit(state, {
      type: "supplyCollateral",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      amountUsd6: parseFixed("1000", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.after.state).not.toBe(state)
    expect(preview.after.metrics.collateralValueUsd6).toBeGreaterThan(preview.before.metrics.collateralValueUsd6)
    expect(preview.after.metrics.healthFactorWad).toBeGreaterThanOrEqual(preview.before.metrics.healthFactorWad)
    expect(preview.validationErrors).toEqual([])
    expect(preview.before.metrics).toMatchObject({
      collateralValueUsd6: expect.any(BigInt),
      borrowCapacityUsd6: expect.any(BigInt),
      totalBorrowedUsd6: expect.any(BigInt),
    })
  })

  it("produces deposit warnings when collateral improves a stressed position without fully restoring safety", () => {
    const state = makeExampleBorrowSystemState()
    const uniPosition = state.accounts["wallet-1"]!.collateralPositions.find(
      (position) => position.marketId === EXAMPLE_UNI_MARKET_ID,
    )!
    uniPosition.collateralShares = parseFixed("4", 18)
    uniPosition.principalTokenAmount = parseFixed("4", 18)

    const preview = simulateDeposit(state, {
      type: "supplyCollateral",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      amountUsd6: parseFixed("250", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.after.metrics.collateralValueUsd6).toBeGreaterThan(preview.before.metrics.collateralValueUsd6)
  })

  it("simulates borrow with reduced capacity and health plus structured preview output", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateBorrow(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("1200", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.actionType).toBe("borrow")
    expect(preview.after.metrics.totalBorrowedUsd6).toBeGreaterThan(preview.before.metrics.totalBorrowedUsd6)
    expect(preview.after.metrics.borrowCapacityUsd6).toBe(preview.before.metrics.borrowCapacityUsd6)
    expect(preview.after.metrics.availableBorrowCapacityUsd6).toBeLessThan(
      preview.before.metrics.availableBorrowCapacityUsd6,
    )
    expect(preview.after.metrics.healthFactorWad).toBeLessThan(preview.before.metrics.healthFactorWad)
    expect(preview.after.state.transactions.at(-1)?.kind).toBe("borrow")
    expect(preview.before.metrics).toMatchObject({
      collateralValueUsd6: expect.any(BigInt),
      totalBorrowedUsd6: expect.any(BigInt),
    })
  })

  it("warns when borrow leaves the position close to liquidation", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = state.accounts["wallet-1"]!.collateralPositions.filter(
      (position) => position.marketId === EXAMPLE_UNI_MARKET_ID,
    )

    const preview = simulateBorrow(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("4500", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.riskLabel).toBe("warning")
    expect(preview.warnings.length).toBeGreaterThan(0)
    expect(preview.after.metrics.healthFactorWad).toBeLessThan(parseFixed("1.5", 18))
  })

  it("rejects borrow simulations above the safe limit with validation feedback", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateBorrow(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("20000", 6),
    })

    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors.length).toBeGreaterThan(0)
    expect(preview.after.state).toBe(state)
  })

  it("uses target-spoke metrics when simulating a borrow", () => {
    const state = makeExampleBorrowSystemState()
    const uniPosition = state.accounts["wallet-1"]!.collateralPositions.find(
      (position) => position.marketId === EXAMPLE_UNI_MARKET_ID,
    )!
    uniPosition.collateralShares = parseFixed("4", 18)
    uniPosition.principalTokenAmount = parseFixed("4", 18)

    expect(calculateCreditMetrics(state, "wallet-1").availableCreditUsd6).toBeGreaterThan(0n)

    const preview = simulateBorrow(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    })

    expect(preview.allowed).toBe(false)
    expect(preview.before.metrics.availableBorrowCapacityUsd6).toBe(0n)
    expect(preview.validationErrors[0]).toContain("not have enough available credit in spoke uni-v3-bluechip")
  })

  it("simulates repay with lower debt, improved health, and full repayment support", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateRepay(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("6200", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.after.metrics.totalBorrowedUsd6).toBe(0n)
    expect(preview.after.metrics.healthFactorWad).toBeNull()
    expect(preview.after.state.accounts["wallet-1"]!.debtPositions).toHaveLength(0)
  })

  it("rejects invalid repay amounts", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateRepay(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: 0n,
    })

    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors).toContain("Repay amount must be positive")
  })

  it("simulates withdraw with lower collateral and blocks unsafe withdrawals", () => {
    const state = makeExampleBorrowSystemState()
    const safePreview = simulateWithdraw(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      amountUsd6: parseFixed("1000", 6),
    })

    expect(safePreview.allowed).toBe(true)
    expect(safePreview.after.metrics.collateralValueUsd6).toBeLessThan(safePreview.before.metrics.collateralValueUsd6)
    expect(safePreview.after.metrics.healthFactorWad).toBeLessThan(safePreview.before.metrics.healthFactorWad)

    const blockedPreview = simulateWithdraw(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      percentBps: 10_000,
    })

    expect(blockedPreview.allowed).toBe(false)
    expect(blockedPreview.validationErrors.length).toBeGreaterThan(0)
  })

  it("simulates liquidation previews without mutating the source state", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = parseFixed("18000", 6)
    debt.debtSharesUsd6 = parseFixed("18000", 6)
    const originalDebt = debt.debtSharesUsd6
    const originalTransactions = state.transactions.length

    const preview = simulateLiquidation(state, {
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      repayAmountUsd6: parseFixed("2000", 6),
    })

    expect(preview.allowed).toBe(true)
    expect(preview.riskLabel).toBe("danger")
    expect(preview.after.metrics.totalBorrowedUsd6).toBeLessThan(preview.before.metrics.totalBorrowedUsd6)
    expect(preview.after.metrics.collateralValueUsd6).toBeLessThan(preview.before.metrics.collateralValueUsd6)
    expect(state.accounts["wallet-1"]!.debtPositions[0]!.debtSharesUsd6).toBe(originalDebt)
    expect(state.transactions).toHaveLength(originalTransactions)
  })

  it("rejects liquidation preview for healthy positions", () => {
    const state = makeExampleBorrowSystemState()
    const preview = simulateLiquidation(state, {
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      repayAmountUsd6: parseFixed("2000", 6),
    })

    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors[0]).toContain("not eligible for liquidation")
  })
})
