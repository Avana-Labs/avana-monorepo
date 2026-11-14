import { expect, test } from "vitest"
import { multiplyPreviewFixture } from "./fixtures"
import { mapMultiplyPreviewToActionUi } from "../adapters/multiply-preview-mapper"
import { formatActionFeeSummary } from "../formatters"

test("Multiply review fee agrees with the success receipt fee", () => {
  const preview = multiplyPreviewFixture({
    before: { collateralValueUsd: 0, debtValueUsd: 0, multiplier: 1, ltv: 0, healthFactor: "infinity", netApy: 0 },
    after: { collateralValueUsd: 3000, debtValueUsd: 2000, multiplier: 3, ltv: 2 / 3, healthFactor: 1.2, netApy: 0.05 },
  })
  const ui = mapMultiplyPreviewToActionUi(preview, {
    collateralSymbol: "ETH",
    borrowSymbol: "USDC",
    collateralAmount: 1,
    collateralPriceUsd: 1000,
    marketLabel: "ETH / USDC",
    collateralApy: 0.05,
    borrowApy: 0.03,
    multiplier: 3,
    maxLtv: 0.8,
  })
  expect(ui.networkFeeLabel).toBe(formatActionFeeSummary(ui.amountUsd!))
})
