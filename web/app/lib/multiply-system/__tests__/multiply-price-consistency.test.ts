import { describe, expect, it } from "vitest"
import { applyMultiplyAction, simulateMultiply, type MultiplySystemState } from "@/app/lib/multiply-engine"
import { buildMultiplyCatalogMarketsRecord } from "@/app/lib/multiply-system/catalog"
import { buildPortfolioMultiplyData } from "@/app/lib/multiply-system/read-model"

function freshState(): MultiplySystemState {
  return {
    now: 1_700_000_000_000,
    markets: buildMultiplyCatalogMarketsRecord(),
    positions: {},
    transactions: [],
  }
}

// The confirm preview values a multiply at the LIVE oracle price; the dashboard renders
// the persisted position. Threading the live price into the engine (action.collateralPriceUsd)
// makes the two identical. These cases use a live price that DIFFERS from the catalog seed
// price so a regression (position priced at the catalog seed) would fail loudly.
const CASES = [
  { marketId: "eth-usdt", collateralAmount: 10, livePrice: 2_000, multipliers: [1.5, 2.0] },
  { marketId: "aave-gho", collateralAmount: 5, livePrice: 140, multipliers: [1.3, 1.6] },
] as const

describe("multiply preview equals the created dashboard position", () => {
  for (const testCase of CASES) {
    for (const multiplier of testCase.multipliers) {
      it(`${testCase.marketId} @ ${multiplier}x — preview exposure/debt/liq == dashboard`, () => {
        const state = freshState()
        const market = state.markets[testCase.marketId]!
        // Sanity: the live price we test with is genuinely different from the seed price,
        // so this test would fail if the engine ignored the override and used the seed.
        expect(testCase.livePrice).not.toBe(market.collateralAsset.priceUsd)

        // Preview: what the confirm screen shows (engine simulation at the live price).
        const preview = simulateMultiply({
          market,
          collateralAmount: testCase.collateralAmount,
          selectedMultiplier: multiplier,
          collateralPriceOverrideUsd: testCase.livePrice,
        })

        // Execute: creates the persisted position via the same live price.
        const nextState = applyMultiplyAction(state, {
          type: "multiply",
          walletId: "wallet-1",
          marketId: testCase.marketId,
          collateralAmount: testCase.collateralAmount,
          selectedMultiplier: multiplier,
          collateralPriceUsd: testCase.livePrice,
        })

        // Dashboard: what the portfolio renders for that created position.
        const dashboard = buildPortfolioMultiplyData("wallet-1", nextState)
        const row = dashboard.lpCollaterals.find((entry) => entry.marketId === testCase.marketId)!

        expect(row.collateralUsd).toBeCloseTo(preview.after.collateralValueUsd, 6)
        expect(row.debtUsd).toBeCloseTo(preview.after.debtValueUsd, 6)
        expect(row.liquidationPriceUsd).toBeCloseTo(preview.after.liquidationPrice!, 6)
      })
    }
  }

  it("without the live price override the position falls back to the catalog seed price", () => {
    const state = freshState()
    const nextState = applyMultiplyAction(state, {
      type: "multiply",
      walletId: "wallet-1",
      marketId: "eth-usdt",
      collateralAmount: 10,
      selectedMultiplier: 2,
    })
    const seedPreview = simulateMultiply({
      market: state.markets["eth-usdt"]!,
      collateralAmount: 10,
      selectedMultiplier: 2,
    })
    const row = buildPortfolioMultiplyData("wallet-1", nextState).lpCollaterals.find(
      (entry) => entry.marketId === "eth-usdt",
    )!
    expect(row.collateralUsd).toBeCloseTo(seedPreview.after.collateralValueUsd, 6)
  })
})
