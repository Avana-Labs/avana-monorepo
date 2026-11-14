import { describe, expect, it } from "vitest"
import { buildPositionContext } from "../position-context"
import { positionInputFromRows } from "../position-context-adapter"

describe("positionInputFromRows", () => {
  it("maps a number-native multiply row with its token parameter", () => {
    const input = positionInputFromRows({
      position: {
        _id: "pos_m",
        product: "multiply",
        marketSlug: "eth",
        assetId: "ETH",
        status: "open",
        collateralValueUsd: 12_000,
        debtValueUsd: 6_000,
        lastUpdatedAt: 1_700_000_000_000,
      },
      market: { maxLtvPct: 80, constituents: [{ symbol: "ETH", weight: 1 }] },
      parameter: { borrowAprPct: 4, collateralFactorPct: 80, liquidationThresholdPct: 82.5 },
      asOf: 1_700_000_100_000,
    })
    expect(input).toMatchObject({
      positionId: "pos_m",
      collateralValueUsd: 12_000,
      debtValueUsd: 6_000,
      maxLtvPct: 80,
      liquidationThresholdPct: 82.5,
      borrowApyPct: 4,
      lpFeeApr7dPct: undefined,
    })
    // End-to-end: the mapped input drives a correct health factor. 12000*0.825/6000
    expect(buildPositionContext(input, input.lastUpdatedAt).healthFactor).toBeCloseTo(1.65, 10)
  })

  it("converts borrow usd6 decimal strings and takes LP constituents from the market", () => {
    const input = positionInputFromRows({
      position: {
        _id: "pos_b",
        product: "borrow",
        marketSlug: "eth-usdc",
        status: "open",
        collateralValueUsd6: "10000000000", // 10,000.000000
        debtValueUsd6: "4000000000", // 4,000.000000
        lastUpdatedAt: 1,
      },
      market: {
        maxLtvPct: 55,
        constituents: [
          { symbol: "ETH", weight: 0.5 },
          { symbol: "USDC", weight: 0.5 },
        ],
      },
      parameter: { liquidationThresholdPct: 65 },
      asOf: 2,
    })
    expect(input.collateralValueUsd).toBe(10_000)
    expect(input.debtValueUsd).toBe(4_000)
    expect(input.constituents.map((c) => c.symbol)).toEqual(["ETH", "USDC"])
  })

  it("falls back to an assetId single-leg when the market has no constituents", () => {
    const input = positionInputFromRows({
      position: { _id: "p", product: "borrow", marketSlug: "m", assetId: "GHO", status: "open", debtValueUsd6: "0" },
      market: { maxLtvPct: 70 },
      asOf: 5,
    })
    expect(input.constituents).toEqual([{ symbol: "GHO", weight: 1 }])
  })

  it("leaves rate/threshold undefined when no parameter row is joined (engine stays null-honest)", () => {
    const input = positionInputFromRows({
      position: {
        _id: "p",
        product: "borrow",
        marketSlug: "m",
        status: "open",
        collateralValueUsd6: "1000000000",
        debtValueUsd6: "500000000",
        lastUpdatedAt: 9,
      },
      market: { maxLtvPct: 60 },
      asOf: 9,
    })
    expect(input.liquidationThresholdPct).toBeUndefined()
    expect(input.borrowApyPct).toBeUndefined()
    // The engine still derives a liquidation threshold from maxLtv and produces a finite HF.
    expect(buildPositionContext(input, input.lastUpdatedAt).healthFactor).not.toBeNull()
  })
})
