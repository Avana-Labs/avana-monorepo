import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import {
  buildHomeBorrowPreview,
  buildHomeClaimPreview,
  buildHomeRemovePreview,
  buildHomeRepayPreview,
  selectHomeDebtMap,
  selectHomeBorrowTokensForMarket,
} from "@/app/lib/borrow-system/home-runtime"
import { HOME_CLAIM_POSITIONS } from "@/app/lib/borrow-system/home-contracts"

describe("home runtime", () => {
  it("only exposes borrowables that belong to the selected market spoke", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const tokens = selectHomeBorrowTokensForMarket(state, "demo-wallet", "uni-v3-bluechip-weth-usdc")

    expect(tokens.length).toBeGreaterThan(0)
    expect(tokens.every((token) => token.id.startsWith("uni-v3-bluechip:"))).toBe(true)
  })

  it("maps home debt by spoke so collateral in the same spoke sees the same debt context", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const debtByMarket = selectHomeDebtMap(state, "demo-wallet")

    expect(debtByMarket["uni-v3-bluechip-weth-usdc"]).toBe(1200)
    expect(debtByMarket["uni-v3-bluechip-wbtc-weth"]).toBe(1200)
    expect(debtByMarket["uni-v3-stable-usdc-usdt"]).toBe(800)
  })

  it("builds borrow previews from spoke-scoped engine checks", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const preview = buildHomeBorrowPreview(
      state,
      "demo-wallet",
      "uni-v3-bluechip-weth-usdc",
      "uni-v3-bluechip:usdc",
      4000,
    )

    expect(preview.isValid).toBe(false)
    expect(preview.exceedsBorrowPower).toBe(true)
    expect(preview.ctaLabel).toBe("Exceeds borrow power")
  })

  it("flags unsafe removals when the selected spoke would fall below health factor 1", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const preview = buildHomeRemovePreview(state, "demo-wallet", "uni-v3-stable-usdc-usdt", 100)

    expect(preview.isUnsafe).toBe(true)
    expect(preview.safePercent).toBeLessThan(100)
  })

  it("returns an empty remove preview when the wallet has no collateral in that market", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const preview = buildHomeRemovePreview(state, "demo-wallet", "aero-basic-volatile-well-weth", 25)

    expect(preview.safePercent).toBe(0)
    expect(preview.removeUsd).toBe(0)
    expect(preview.ctaLabel).toBe("No collateral supplied")
  })

  it("repay previews use the real debt position and improve health after repayment", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const spokeId = state.markets["uni-v3-bluechip-weth-usdc"]?.spokeId
    const debt = state.accounts["demo-wallet"]?.debtPositions.find((position) => position.spokeId === spokeId)
    if (!debt) {
      throw new Error("Expected bluechip debt position")
    }
    const debtUsd = buildHomeRepayPreview(state, "demo-wallet", debt.id, 0).remainingDebtUsd
    const borrowApr = (Number(debt.borrowRateWad) / 1e18) * 100

    const preview = buildHomeRepayPreview(state, "demo-wallet", debt.id, 300)

    expect(preview.isValid).toBe(true)
    expect(preview.remainingDebtUsd).toBeLessThan(debtUsd)
    expect(preview.yearlyInterestSavedUsd).toBeCloseTo(300 * (borrowApr / 100), 2)
  })

  it("does not fabricate claimable rewards when the wallet has no reward positions", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    state.accounts["demo-wallet"]!.rewardPositions = []
    const selections = Object.fromEntries(HOME_CLAIM_POSITIONS.map((position) => [position.id, true]))

    const preview = buildHomeClaimPreview(state, "demo-wallet", HOME_CLAIM_POSITIONS, selections, null)

    expect(preview.selectedTotalUsd).toBe(0)
    expect(preview.effectiveClaimUsd).toBe(0)
  })
})
