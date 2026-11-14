import { describe, expect, it } from "vitest"
import {
  mapBorrowRemovePreviewToActionUi,
  mapBorrowRepayPreviewToActionUi,
  mapBorrowSupplyPreviewToActionUi,
  mapBorrowTransactionPreviewToActionUi,
} from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { borrowPreviewFixture } from "@/app/lib/action-system/__tests__/fixtures"

describe("borrow preview mappers", () => {
  const preview = borrowPreviewFixture()

  it("maps borrow metrics from spec including LTV and liquidation threshold", () => {
    const ui = mapBorrowTransactionPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 1000,
      marketLabel: "USDC · Core",
      ratePct: 5.2,
      balanceLabel: "Available to Borrow",
      balanceUsd: 5000,
      liquidationThresholdPct: 82.5,
      maxBorrowUsd: 5000,
      creditScopeLabel: "Uniswap Bluechip",
    })

    expect(ui.quoteId).toBe(preview.intent.id)

    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Spoke",
      "Position APY",
      "LTV in spoke",
      "Liquidation threshold",
      "Borrowing power in spoke",
      "Position equity in spoke",
      "Net collateral in spoke",
      "Health factor in spoke",
    ])
    // LTV live-updates from before → after (0.25 → 0.35 in the fixture). Percentages now use
    // fixed 2dp everywhere (formatActionPercent unified with formatActionRatioPercent).
    expect(ui.metrics.find((row) => row.id === "ltv")?.value).toBe("25.00% → 35.00%")
    expect(ui.metrics.find((row) => row.id === "liquidation-threshold")?.value).toBe("82.50%")
    // Max borrow respects the collateral factor (pre-borrow available credit).
    expect(ui.maxAmount).toBe(5000)
  })

  it("omits the liquidation-threshold row when not provided", () => {
    const ui = mapBorrowTransactionPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 1000,
      marketLabel: "USDC · Core",
      ratePct: 5.2,
      balanceLabel: "Available to Borrow",
      balanceUsd: 5000,
    })

    expect(ui.metrics.some((row) => row.id === "liquidation-threshold")).toBe(false)
    expect(ui.metrics.some((row) => row.id === "ltv")).toBe(true)
    // Falls back to the pre-borrow borrowing power (5000 in the fixture).
    expect(ui.maxAmount).toBe(5000)
  })

  it("maps repay-specific metrics", () => {
    const ui = mapBorrowRepayPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 500,
      marketLabel: "USDC · Core",
      remainingDebtUsd: 3000,
      yearlyInterestSavedUsd: 42,
      creditScopeLabel: "Uniswap Bluechip",
    })

    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Spoke",
      "Remaining debt",
      "Health factor after in spoke",
      "Interest saved (est. yearly)",
    ])
  })

  it("expresses volatile-asset repayment in token units while keeping debt math in USD", () => {
    const ui = mapBorrowRepayPreviewToActionUi(preview, {
      symbol: "ETH",
      amountUsd: 500,
      priceUsd: 2_000,
      marketLabel: "ETH · Core",
      remainingDebtUsd: 2000,
      yearlyInterestSavedUsd: 42,
    })

    expect(ui.amountLabel).toBe("0.25 ETH")
    expect(ui.amountUsdLabel).toBe("$500")
    expect(ui.maxAmount).toBe(1.25)
  })

  it("blocks an over-repay (amount greater than outstanding debt)", () => {
    const ui = mapBorrowRepayPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 500,
      marketLabel: "USDC · Core",
      remainingDebtUsd: 0,
      yearlyInterestSavedUsd: 0,
      exceedsDebt: true,
    })

    expect(ui.allowed).toBe(false)
    expect(ui.blockedReason).toBe("Amount exceeds outstanding debt. Maximum repay is $2,500.00.")
  })

  // The repay field is typed in the debt token; the limit read in USD ("Maximum repay is $899.70").
  it("states the over-repay limit and outstanding debt in the debt token when priced", () => {
    const ui = mapBorrowRepayPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 5000,
      priceUsd: 1,
      marketLabel: "USDC · Core",
      remainingDebtUsd: 0,
      yearlyInterestSavedUsd: 0,
      exceedsDebt: true,
    })
    expect(ui.blockedReason).toBe("Amount exceeds outstanding debt. Maximum repay is 2,500 USDC.")
    expect(ui.balanceValue).toBe("2,500 USDC")
    expect(ui.rateValue).toBe("5,000 USDC")
  })

  it("allows a repay within the outstanding debt", () => {
    const ui = mapBorrowRepayPreviewToActionUi(preview, {
      symbol: "USDC",
      amountUsd: 500,
      marketLabel: "USDC · Core",
      remainingDebtUsd: 2500,
      yearlyInterestSavedUsd: 42,
      exceedsDebt: false,
    })

    expect(ui.allowed).toBe(true)
    expect(ui.blockedReason).toBeNull()
  })

  it("maps supply metrics including borrowable assets", () => {
    const ui = mapBorrowSupplyPreviewToActionUi(preview, {
      symbol: "WETH / USDC",
      amountUsd: 2000,
      marketLabel: "WETH / USDC",
      poolLabel: "WETH / USDC",
      collateralSymbol: "WETH",
      borrowSymbol: "USDC",
      collateralFactorPct: 80,
      collateralRiskPct: 5,
      borrowableAssetsLabel: "USDC, GHO",
      borrowableAssetSymbols: ["USDC", "GHO"],
      creditScopeLabel: "Uniswap Bluechip",
    })

    expect(ui.amountValue).toBe("2000")
    expect(ui.assetLabel).toBe("WETH / USDC")
    expect(ui.borrowSymbol).toBe("USDC")

    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Spoke",
      "Collateral factor",
      "Collateral risk",
      "Borrowable assets",
      "Borrowing power in spoke",
      "Health factor in spoke",
    ])
    expect(ui.metrics.find((row) => row.id === "borrowable-assets")?.tokenSymbols).toEqual(["USDC", "GHO"])
  })

  it("humanizes a leaky blocked reason so no internal ids reach the banner", () => {
    const blocked = borrowPreviewFixture({
      allowed: false,
      validationErrors: ["Wallet wallet-1 does not have enough available credit in spoke uni-v3-bluechip"],
    })
    const ui = mapBorrowTransactionPreviewToActionUi(blocked, {
      symbol: "USDC",
      amountUsd: 999999,
      marketLabel: "USDC · Core",
      ratePct: 5.2,
      balanceLabel: "Available to Borrow",
      balanceUsd: 5000,
      maxBorrowUsd: 5000,
      creditScopeLabel: "Uniswap Bluechip",
    })

    expect(ui.blockedReason).toBe("Maximum safe borrow is $5,000.00, limited by borrowing power in Uniswap Bluechip.")
    expect(ui.blockedReason).not.toMatch(/spoke|wallet-1|insolvent/i)
  })

  it("p0-01: health factor 0n (underwater / zero liquidation value) renders as 0, not ∞", () => {
    const underwater = borrowPreviewFixture({
      before: {
        ...preview.before,
        totalBorrowedUsd6: 1_000_000_000n,
        healthFactorWad: 0n,
      },
      after: {
        ...preview.after,
        totalBorrowedUsd6: 1_000_000_000n,
        healthFactorWad: 0n,
      },
      riskLabel: "danger",
    })
    const ui = mapBorrowTransactionPreviewToActionUi(underwater, {
      symbol: "USDC",
      amountUsd: 100,
      marketLabel: "USDC · Core",
      ratePct: 5.2,
      balanceLabel: "Available to Borrow",
      balanceUsd: 0,
      creditScopeLabel: "Uniswap Bluechip",
    })

    const health = ui.metrics.find((row) => row.id === "health-factor")
    expect(health?.value).toBe("0.00 → 0.00")
    expect(health?.value).not.toMatch(/∞/)
    expect(ui.risk?.level).toBe("danger")
  })

  it("p0-01: null health factor (no debt) still renders as ∞", () => {
    const noDebt = borrowPreviewFixture({
      before: {
        ...preview.before,
        totalBorrowedUsd6: 0n,
        healthFactorWad: null,
      },
      after: {
        ...preview.after,
        totalBorrowedUsd6: 0n,
        healthFactorWad: null,
      },
      riskLabel: "safe",
    })
    const ui = mapBorrowTransactionPreviewToActionUi(noDebt, {
      symbol: "USDC",
      amountUsd: 0,
      marketLabel: "USDC · Core",
      ratePct: 5.2,
      balanceLabel: "Available to Borrow",
      balanceUsd: 5000,
      creditScopeLabel: "Uniswap Bluechip",
    })

    const health = ui.metrics.find((row) => row.id === "health-factor")
    expect(health?.value).toMatch(/∞/)
  })

  it("maps remove metrics", () => {
    const removePreview = {
      ...preview,
      after: { ...preview.after, collateralValueUsd6: 7_500_000_000n },
    }
    const ui = mapBorrowRemovePreviewToActionUi(removePreview, {
      percent: 25,
      safePercent: 60,
      removeUsd: 2500,
      marketLabel: "WETH · Core",
      positionApyPct: 3.5,
      creditScopeLabel: "Uniswap Bluechip",
    })

    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Spoke",
      "Annual earnings",
      "Borrowing power in spoke",
      "Position equity in spoke",
      "Net collateral in spoke",
      "Health factor in spoke",
    ])
    expect(ui.amountUsd).toBe(2500)
    expect(ui.amountValue).toBe("25")
    expect(ui.amountUnitLabel).toBe("%")
    expect(ui.assetLabel).toBe("%")
    expect(ui.amountUsdLabel).toBe("$2,500.00")
    expect(ui.balanceValue).toBe("$2,500.00")
    expect(ui.maxAmount).toBe(60)
  })

  it("keeps the requested removal amount visible when the engine blocks the action", () => {
    const blockedPreview = {
      ...preview,
      allowed: false,
      after: { ...preview.after, collateralValueUsd6: preview.before.collateralValueUsd6 },
      validationErrors: ["Removal would make the position unsafe."],
    }
    const ui = mapBorrowRemovePreviewToActionUi(blockedPreview, {
      percent: 100,
      safePercent: 76,
      removeUsd: 43_596,
      marketLabel: "cbBTC / USDC",
      positionApyPct: 2.85,
    })

    expect(ui.amountUsd).toBe(43_596)
    expect(ui.amountUsdLabel).toBe("$43,596.00")
    expect(ui.balanceValue).toBe("$43,596.00")
    expect(ui.allowed).toBe(false)
  })
})
