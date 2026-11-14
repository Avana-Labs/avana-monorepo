import { describe, expect, it } from "vitest"
import {
  mapClosePreviewToActionUi,
  mapDeleveragePreviewToActionUi,
  mapMultiplyPreviewToActionUi,
} from "@/app/lib/action-system/adapters/multiply-preview-mapper"
import { multiplyPreviewFixture } from "@/app/lib/action-system/__tests__/fixtures"

describe("multiply preview mappers", () => {
  const preview = multiplyPreviewFixture()

  it("maps multiply metrics including net APY and liquidation price", () => {
    const ui = mapMultiplyPreviewToActionUi(preview, {
      collateralSymbol: "WETH",
      borrowSymbol: "USDC",
      collateralAmount: 2,
      collateralPriceUsd: 3_500,
      marketLabel: "WETH · USDC",
      collateralApy: 0.0382,
      borrowApy: 0.048,
      multiplier: 2.5,
      maxLtv: 0.8,
    })

    expect(ui.quoteId).toBe(preview.intent.id)
    expect(ui.loopCount).toBe(2)
    expect(ui.executionSteps?.map((step) => step.label)).toEqual([
      "Supply initial collateral",
      "Loop 1: Borrow",
      "Loop 1: Swap to collateral",
      "Loop 1: Resupply collateral",
      "Loop 2: Borrow",
      "Loop 2: Swap to collateral",
      "Loop 2: Resupply collateral",
    ])

    expect(ui.marketBreakdown).toBeUndefined()
    expect(ui.marketValue).toBe("")
    expect(ui.rateLabel).toBe("")
    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Collateral",
      "Collateral value",
      "Target leverage",
      "Looped exposure",
      "USDC borrowed",
      "Position exposure",
      "Position debt",
      "Position leverage",
      "Borrow capacity remaining",
      "Projected LTV",
      "Projected health factor",
      "Projected net APY",
      "Liquidation price",
    ])
    expect(ui.amountLabel).toBe("2 WETH")
    expect(ui.amountValue).toBe("2")
    expect(ui.amountUsdLabel).toBe("$7,000")
    expect(ui.balanceLabel).toBe("Selected leverage")
    expect(ui.metrics.find((row) => row.id === "looped-exposure")?.value).toBe("$2,000")
    expect(ui.metrics.find((row) => row.id === "borrow-capacity")?.value).toBe("$2,100")
    expect(ui.metrics.find((row) => row.id === "borrow-capacity")?.tone).toBe("warning")
    expect(ui.metrics.find((row) => row.id === "liq-price")?.value).not.toBe("—")
  })

  it("revalues the full preview from the live collateral oracle price", () => {
    const ui = mapMultiplyPreviewToActionUi(preview, {
      collateralSymbol: "AAVE",
      borrowSymbol: "GHO",
      collateralAmount: 2,
      collateralPriceUsd: 140,
      catalogCollateralPriceUsd: 280,
      marketLabel: "AAVE · GHO",
      collateralApy: 0.076,
      borrowApy: 0.039,
      multiplier: 2.5,
      maxLtv: 0.5,
    })

    expect(ui.amountUsdLabel).toBe("$280")
    expect(ui.metrics.find((row) => row.id === "collateral-value")?.value).toBe("$280")
    expect(ui.metrics.find((row) => row.id === "looped-exposure")?.value).toBe("$1,000")
  })

  it("flags a health factor in [1.15, 1.2) as danger, aligned with the shared danger band", () => {
    // 1.18 sits above the old 1.15 cutoff but inside the shared danger band (hf < 1.2).
    // The red HF bar and this banner must now agree instead of firing at different points.
    const nearLiquidation = multiplyPreviewFixture({
      riskLabel: "warning",
      after: {
        collateralValueUsd: 12_000,
        debtValueUsd: 7_500,
        multiplier: 2.5,
        ltv: 0.62,
        healthFactor: 1.18,
        netApy: 8.1,
      },
    })
    const ui = mapMultiplyPreviewToActionUi(nearLiquidation, {
      collateralSymbol: "WETH",
      borrowSymbol: "USDC",
      collateralAmount: 2,
      collateralPriceUsd: 3_500,
      marketLabel: "WETH · USDC",
      collateralApy: 0.0382,
      borrowApy: 0.048,
      multiplier: 2.5,
      maxLtv: 0.8,
    })

    expect(ui.risk?.level).toBe("danger")
    expect(ui.metrics.find((row) => row.id === "hf")?.tone).toBe("danger")
  })

  it("maps deleverage unwind metrics", () => {
    const ui = mapDeleveragePreviewToActionUi(preview, {
      marketLabel: "WETH · USDC",
      targetMultiplier: 1.5,
      collateralSymbol: "WETH",
    })

    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Exposure",
      "Estimated debt",
      "LTV",
      "Health factor",
      "Net APY",
      "Liquidation price",
    ])
    expect(ui.amountLabel).toBe("1.50x WETH")
    expect(ui.amountValue).toBe("1.50x")
    expect(ui.assetSymbol).toBe("WETH")
  })

  it("maps a full close into an explicit unwind receipt", () => {
    const ui = mapClosePreviewToActionUi(preview, {
      marketLabel: "WETH · USDC",
      collateralSymbol: "WETH",
    })

    expect(ui.amountLabel).toBe("Full close WETH")
    expect(ui.rateLabel).toBe("Final withdrawal")
    expect(ui.metrics.map((row) => row.label)).toEqual([
      "Debt repaid",
      "Collateral unwound",
      "Estimated swap loss",
      "Minimum received",
      "Remaining dust",
    ])
    expect(ui.metrics.find((row) => row.id === "remaining-dust")?.value).toBe("$0.00")
  })

  it("closes against the LIVE collateral price, not the stale catalog price", () => {
    // Observed live: an AAVE/GHO loop held 908.380238986834 AAVE against $41,666.66 of debt.
    // The multiply session revalues positions at the catalog fixture ($105), so close reported
    // $95,380 unwound / $53,713 withdrawn while the dashboard (live oracle $120.18240206615957)
    // showed $109,172 / $67,505 for the same position.
    const debtValueUsd = 41_666.66
    const collateralAmount = 908.380238986834
    const stalePriceUsd = 105
    const livePriceUsd = 120.18240206615957
    const livePreview = {
      ...preview,
      before: { ...preview.before, collateralValueUsd: collateralAmount * stalePriceUsd, debtValueUsd },
      simulationSummary: { ...preview.simulationSummary, priceImpactPct: 0 },
    }

    const stale = mapClosePreviewToActionUi(livePreview, { marketLabel: "AAVE · GHO", collateralSymbol: "AAVE" })
    const live = mapClosePreviewToActionUi(livePreview, {
      marketLabel: "AAVE · GHO",
      collateralSymbol: "AAVE",
      liveCollateralValueUsd: collateralAmount * livePriceUsd,
    })

    const unwound = (ui: typeof stale) => ui.metrics.find((row) => row.id === "collateral-sold")?.value
    // "$95,379.93" is the exact figure the live close page rendered before this fix.
    expect(unwound(stale)).toBe("$95,379.93")
    expect(unwound(live)).toBe(
      `$${(collateralAmount * livePriceUsd).toLocaleString("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      })}`,
    )
    // Final withdrawal is equity at the live price, ~$13.8K higher than the stale figure.
    expect(live.amountUsd).toBeCloseTo(collateralAmount * livePriceUsd - debtValueUsd, 2)
    expect(live.amountUsd - stale.amountUsd).toBeGreaterThan(13_000)
  })
})
