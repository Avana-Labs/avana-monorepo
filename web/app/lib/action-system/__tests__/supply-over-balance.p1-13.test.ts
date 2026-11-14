import { describe, expect, it } from "vitest"
import { mapBorrowSupplyPreviewToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { borrowPreviewFixture } from "@/app/lib/action-system/__tests__/fixtures"

describe("pledge over-balance validation", () => {
  it("p1-13: surfaces wallet balance cap instead of generic valid-amount copy", () => {
    const preview = borrowPreviewFixture()
    preview.allowed = false
    preview.validationErrors = ["Wallet has insufficient LP balance for this collateral deposit"]

    const ui = mapBorrowSupplyPreviewToActionUi(preview, {
      symbol: "WETH / USDC",
      amountUsd: 12_500,
      marketLabel: "WETH / USDC",
      poolLabel: "WETH / USDC",
      collateralSymbol: "WETH",
      borrowSymbol: "USDC",
      collateralFactorPct: 80,
      collateralRiskPct: 5,
      borrowableAssetsLabel: "USDC",
      borrowableAssetSymbols: ["USDC"],
      walletBalanceUsd: 10_000,
    })

    expect(ui.maxAmount).toBe(10_000)
    expect(ui.balanceLabel).toBe("Wallet balance")
    expect(ui.blockedReason).toMatch(/Maximum pledge is \$10,000\.00/)
    expect(ui.blockedReason).not.toBe("Enter a valid amount")
  })
})
