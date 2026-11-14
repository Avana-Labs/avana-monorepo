import { describe, expect, it } from "vitest"
import { parseFixed, validateAction } from "@/app/lib/credit-engine"
import {
  EXAMPLE_CURVE_MARKET_ID,
  EXAMPLE_CURVE_USDT_ASSET_ID,
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  EXAMPLE_WALLET_1_DEBT_ID,
  makeExampleBorrowSystemState,
} from "./fixtures"

describe("credit engine action validation", () => {
  it("blocks invalid amounts", () => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: 0n,
    })

    expect(result.allowed).toBe(false)
    expect(result.validationErrors).toContain("Borrow amount must be positive")
  })

  it("blocks actions on missing positions", () => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: "missing-debt",
      amountUsd6: parseFixed("100", 6),
    })

    expect(result.allowed).toBe(false)
    expect(result.validationErrors).toContain("Unknown debt position missing-debt")
  })

  it("blocks borrow above available capacity", () => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("20000", 6),
    })

    expect(result.allowed).toBe(false)
    expect(result.validationErrors[0]).toContain("does not have enough available credit")
  })

  it("blocks unsafe withdraw", () => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      percentBps: 10_000,
    })

    expect(result.allowed).toBe(false)
    expect(result.validationErrors[0]).toContain("insolvent")
  })

  it("returns clear validation errors for missing collateral in the target spoke", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = state.accounts["wallet-1"]!.collateralPositions.filter(
      (position) => position.marketId !== EXAMPLE_CURVE_MARKET_ID,
    )

    const result = validateAction(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_CURVE_MARKET_ID,
      assetId: EXAMPLE_CURVE_USDT_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    })

    expect(result.allowed).toBe(false)
    expect(result.validationErrors).toContain("Wallet wallet-1 has no collateral in spoke curve-crypto")
  })

  it("passes valid actions without validation errors", () => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("300", 6),
    })

    expect(result.allowed).toBe(true)
    expect(result.validationErrors).toEqual([])
  })

  it.each([
    [
      "borrow",
      {
        type: "borrow" as const,
        walletId: "wallet-1",
        marketId: EXAMPLE_UNI_MARKET_ID,
        assetId: EXAMPLE_UNI_USDC_ASSET_ID,
        amountUsd6: 0n,
      },
      "Borrow amount must be positive",
    ],
    [
      "repay",
      { type: "repay" as const, walletId: "wallet-1", debtPositionId: EXAMPLE_WALLET_1_DEBT_ID, amountUsd6: 0n },
      "Repay amount must be positive",
    ],
    [
      "supplyCollateral",
      { type: "supplyCollateral" as const, walletId: "wallet-1", marketId: EXAMPLE_UNI_MARKET_ID, amountUsd6: 0n },
      "Supply amount must be positive",
    ],
  ])("blocks invalid %s amounts with a clear validation error", (_label, action, message) => {
    const state = makeExampleBorrowSystemState()
    const result = validateAction(state, action)

    expect(result.allowed).toBe(false)
    expect(result.validationErrors).toContain(message)
  })
})
