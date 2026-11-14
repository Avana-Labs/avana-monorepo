import { describe, expect, it } from "vitest"
import type { MultiplyPosition, MultiplySystemState } from "@/app/lib/multiply-engine"
import { buildMultiplyCatalogMarketsRecord } from "@/app/lib/multiply-system/catalog"
import { buildPortfolioMultiplyData } from "@/app/lib/multiply-system/read-model"

function stateWith(positions: MultiplyPosition[]): MultiplySystemState {
  return {
    now: 1_700_000_000_000,
    markets: buildMultiplyCatalogMarketsRecord(),
    positions: Object.fromEntries(positions.map((position) => [position.id, position])),
    transactions: [],
  }
}

function zeroDebtPosition(marketId: string): MultiplyPosition {
  return {
    id: `wallet-1:${marketId}`,
    walletId: "wallet-1",
    marketId,
    collateralAmount: 1,
    collateralValueUsd: 5_000,
    debtValueUsd: 0,
    multiplier: 1,
    ltv: 0,
    healthFactor: "infinity",
    liquidationPrice: null,
    netApy: 0,
    openedAt: 1_700_000_000_000,
    lastUpdatedAt: 1_700_000_000_000,
  }
}

describe("multiply credit-health aggregate agrees with the per-row table", () => {
  const marketId = Object.keys(buildMultiplyCatalogMarketsRecord())[0]!

  it("reports ∞ (not —) when positions exist but every one is debt-free", () => {
    const data = buildPortfolioMultiplyData("wallet-1", stateWith([zeroDebtPosition(marketId)]))

    // Every row already renders ∞ (POSITIVE_INFINITY); the hero/credit-health card
    // aggregate must be infinite too so the two do not disagree (∞ vs —).
    expect(data.lpCollaterals.every((row) => !Number.isFinite(row.healthFactor))).toBe(true)
    expect(data.creditLines.averageHealthFactor).toBe(Number.POSITIVE_INFINITY)
  })

  it("reports null (—) only when the wallet has no positions at all", () => {
    const data = buildPortfolioMultiplyData("wallet-1", stateWith([]))
    expect(data.creditLines.averageHealthFactor).toBeNull()
  })

  it("aggregates open positions into the summary (Total Borrowed / Net Value / worst HF) matching the rows", () => {
    const [firstMarketId, secondMarketId] = Object.keys(buildMultiplyCatalogMarketsRecord())
    const one: MultiplyPosition = {
      id: `wallet-1:${firstMarketId}`,
      walletId: "wallet-1",
      marketId: firstMarketId!,
      collateralAmount: 3,
      collateralValueUsd: 12_000,
      debtValueUsd: 4_000,
      multiplier: 1.5,
      ltv: 33,
      healthFactor: 2.4,
      liquidationPrice: 3_000,
      netApy: 0.03,
      openedAt: 1_700_000_000_000,
      lastUpdatedAt: 1_700_000_000_000,
    }
    const two: MultiplyPosition = {
      id: `wallet-1:${secondMarketId}`,
      walletId: "wallet-1",
      marketId: secondMarketId!,
      collateralAmount: 2,
      collateralValueUsd: 8_000,
      debtValueUsd: 5_500,
      multiplier: 3,
      ltv: 69,
      healthFactor: 1.3,
      liquidationPrice: 2_000,
      netApy: 0.05,
      openedAt: 1_700_000_000_000,
      lastUpdatedAt: 1_700_000_000_000,
    }
    const data = buildPortfolioMultiplyData("wallet-1", stateWith([one, two]))

    // Summary must NOT read $0 while open rows exist: Total Borrowed = Σ debt,
    // collateral = Σ collateral, Net Value = Σ(collateral − debt), HF = worst.
    const rowDebt = data.lpCollaterals.reduce((sum, row) => sum + row.debtUsd, 0)
    const rowCollateral = data.lpCollaterals.reduce((sum, row) => sum + row.collateralUsd, 0)
    expect(data.lpCollaterals).toHaveLength(2)
    expect(data.creditLines.totalBorrowedUsd).toBe(9_500)
    expect(data.creditLines.totalBorrowedUsd).toBe(rowDebt)
    expect(data.creditLines.totalCollateralUsd).toBe(20_000)
    expect(data.creditLines.totalCollateralUsd).toBe(rowCollateral)
    expect(data.creditLines.totalCollateralUsd - data.creditLines.totalBorrowedUsd).toBe(10_500)
    // HF is recomputed live from collateral/debt/threshold (never the value frozen at open), so the
    // aggregate is the worst of the per-row HFs the table actually renders — not a stored figure.
    const finiteRowHfs = data.lpCollaterals.map((row) => row.healthFactor).filter((hf) => Number.isFinite(hf))
    expect(data.creditLines.averageHealthFactor).toBe(Math.min(...finiteRowHfs))
  })

  it("reports the WORST position HF (not the average) so a near-liquidation position isn't hidden", () => {
    const [safeMarketId, riskyMarketId] = Object.keys(buildMultiplyCatalogMarketsRecord())
    const safe = zeroDebtPosition(safeMarketId!) // ∞ (debt-free)
    const risky: MultiplyPosition = {
      id: `wallet-1:${riskyMarketId}`,
      walletId: "wallet-1",
      marketId: riskyMarketId!,
      collateralAmount: 2,
      collateralValueUsd: 10_000,
      debtValueUsd: 7_500,
      multiplier: 4,
      ltv: 75,
      healthFactor: 1.25,
      liquidationPrice: 4_000,
      netApy: 0,
      openedAt: 1_700_000_000_000,
      lastUpdatedAt: 1_700_000_000_000,
    }
    const data = buildPortfolioMultiplyData("wallet-1", stateWith([safe, risky]))
    // An average would hide the risky position (behind the ∞ one); the wallet HF must be
    // the closest-to-liquidation position — the (recomputed) HF of the only row with debt.
    const riskyRow = data.lpCollaterals.find((row) => Number.isFinite(row.healthFactor))!
    expect(data.creditLines.averageHealthFactor).toBe(riskyRow.healthFactor)
    expect(data.creditLines.averageHealthFactor).toBeLessThan(2)
  })

  it("recomputes per-row leverage and health factor from the LIVE collateral price, not the value frozen at open", () => {
    const market = buildMultiplyCatalogMarketsRecord()[marketId]!
    const openPrice = market.collateralAsset.priceUsd
    // Opened at 2x: equity = collateral - debt, debt = collateral / 2.
    const collateralAmount = 4
    const openCollateralUsd = collateralAmount * openPrice
    const debtValueUsd = openCollateralUsd / 2
    const position: MultiplyPosition = {
      id: `wallet-1:${marketId}`,
      walletId: "wallet-1",
      marketId,
      collateralAmount,
      collateralValueUsd: openCollateralUsd,
      debtValueUsd,
      multiplier: 2,
      ltv: 50,
      healthFactor: (openCollateralUsd * market.risk.liquidationThreshold) / debtValueUsd,
      liquidationPrice: 0,
      netApy: 0.04,
      openedAt: 1_700_000_000_000,
      lastUpdatedAt: 1_700_000_000_000,
    }

    // Collateral price rises 25% → collateral up, debt fixed → leverage falls below 2x and HF rises.
    const livePrice = openPrice * 1.25
    const data = buildPortfolioMultiplyData("wallet-1", stateWith([position]), [], (symbol) =>
      symbol === market.collateralAsset.symbol ? livePrice : undefined,
    )

    const row = data.lpCollaterals[0]!
    const liveCollateralUsd = collateralAmount * livePrice
    const expectedLeverage = liveCollateralUsd / (liveCollateralUsd - debtValueUsd)
    const expectedHf = (liveCollateralUsd * market.risk.liquidationThreshold) / debtValueUsd

    // The frozen values would be 2.00x / the open HF; the live values must differ and match the math.
    expect(row.multiplier).toBeCloseTo(expectedLeverage, 6)
    expect(row.multiplier).toBeLessThan(2)
    expect(row.healthFactor).toBeCloseTo(expectedHf, 6)
    expect(row.healthFactor).toBeGreaterThan(position.healthFactor as number)
    expect(data.positions[0]!.leverage).toBeCloseTo(expectedLeverage, 6)
    expect(data.creditLines.averageHealthFactor).toBeCloseTo(expectedHf, 6)
  })
})
