import { describe, expect, it } from "vitest"

import { buildInterestRateModelParams } from "@/app/lib/borrow-detail/protocol-parameters"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import {
  MULTIPLY_COLLATERAL_FACTORS,
  MULTIPLY_LIQUIDATION_THRESHOLDS,
  MULTIPLY_TOKEN_AVAILABLE_USD,
  MULTIPLY_TOKEN_BORROW_APYS,
  MULTIPLY_TOKEN_LOGOS,
  MULTIPLY_TOKEN_SUPPLY_APYS,
} from "@/app/lib/multiply-sim"

import {
  MULTIPLY_ALLOCATION_SEED_ROWS,
  MULTIPLY_IRM_SEED_ROWS,
  MULTIPLY_TOKEN_PARAM_SEED_ROWS,
} from "../inputs/multiply-catalog-seed"

const EXPECTED_MULTIPLY_MARKET_COUNT = 20
const EXPECTED_TOKEN_ROWS = [
  "ETH",
  "stETH",
  "wstETH",
  "rETH",
  "cbETH",
  "USDT",
  "USDC",
  "DAI",
  "GHO",
  "crvUSD",
  "EURC",
  "WBTC",
  "cbBTC",
  "AAVE",
  "UNI",
  "CRV",
] as const

describe("MULTIPLY_IRM_SEED_ROWS parity", () => {
  it("emits one row per multiply market and 20 total", () => {
    expect(MULTIPLY_IRM_SEED_ROWS.length).toBe(MULTIPLY_MARKET_CATALOG.length)
    expect(MULTIPLY_IRM_SEED_ROWS.length).toBe(EXPECTED_MULTIPLY_MARKET_COUNT)
  })

  it("every seed row's slug maps to a real multiply market", () => {
    const catalogSlugs = new Set(MULTIPLY_MARKET_CATALOG.map((m) => m.id))
    for (const row of MULTIPLY_IRM_SEED_ROWS) {
      expect(catalogSlugs.has(row.slug)).toBe(true)
    }
  })

  it("IRM parameter values match buildInterestRateModelParams(market.id, borrowApy*100)", () => {
    // Spot-check every seed row against the mock derivation. Cheap and gives full coverage.
    const marketById = new Map(MULTIPLY_MARKET_CATALOG.map((m) => [m.id, m]))
    for (const row of MULTIPLY_IRM_SEED_ROWS) {
      const market = marketById.get(row.slug)!
      expect(market).toBeDefined()
      const params = buildInterestRateModelParams(market.id, market.economics.borrowApy * 100)
      expect(row.optimalUtilizationPct).toBe(params.optimalUtilizationPct)
      expect(row.slopeBelowOptimalPct).toBe(params.slopeBelowOptimalPct)
      expect(row.slopeAboveOptimalPct).toBe(params.slopeAboveOptimalPct)
      expect(row.baseBorrowRatePct).toBe(params.baseBorrowRatePct)
    }
  })
})

describe("MULTIPLY_ALLOCATION_SEED_ROWS parity", () => {
  it("length = 20 (one row per market)", () => {
    expect(MULTIPLY_ALLOCATION_SEED_ROWS.length).toBe(EXPECTED_MULTIPLY_MARKET_COUNT)
    expect(MULTIPLY_ALLOCATION_SEED_ROWS.length).toBe(MULTIPLY_MARKET_CATALOG.length)
  })

  it("every allocation row is self-pointing (rowKey='self', sharePct=100, poolSlug=marketSlug)", () => {
    for (const row of MULTIPLY_ALLOCATION_SEED_ROWS) {
      expect(row.rowKey).toBe("self")
      expect(row.sharePct).toBe(100)
      expect(row.poolSlug).toBe(row.marketSlug)
    }
  })

  it("valueUsd equals the market's headline available liquidity", () => {
    const marketById = new Map(MULTIPLY_MARKET_CATALOG.map((m) => [m.id, m]))
    for (const row of MULTIPLY_ALLOCATION_SEED_ROWS) {
      const market = marketById.get(row.marketSlug)!
      expect(market).toBeDefined()
      expect(row.valueUsd).toBe(market.economics.availableLiquidityUsd)
    }
  })
})

describe("MULTIPLY_TOKEN_PARAM_SEED_ROWS parity", () => {
  it("length = 16 (one row per known multiply-sim symbol)", () => {
    expect(MULTIPLY_TOKEN_PARAM_SEED_ROWS.length).toBe(EXPECTED_TOKEN_ROWS.length)
    expect(MULTIPLY_TOKEN_PARAM_SEED_ROWS.length).toBe(16)
  })

  it("each row's fields match the multiply-sim maps for its symbol", () => {
    const bySymbol = new Map(MULTIPLY_TOKEN_PARAM_SEED_ROWS.map((row) => [row.symbol, row]))
    for (const symbol of EXPECTED_TOKEN_ROWS) {
      const row = bySymbol.get(symbol)
      expect(row, `expected row for symbol ${symbol}`).toBeDefined()
      if (!row) continue

      const supplyRaw = MULTIPLY_TOKEN_SUPPLY_APYS[symbol]!
      const borrowRaw = MULTIPLY_TOKEN_BORROW_APYS[symbol]!
      const available = MULTIPLY_TOKEN_AVAILABLE_USD[symbol]!
      const cf = MULTIPLY_COLLATERAL_FACTORS[symbol]!
      const lt = MULTIPLY_LIQUIDATION_THRESHOLDS[symbol]!
      const logo = MULTIPLY_TOKEN_LOGOS[symbol]

      expect(row.supplyApyPct).toBe(Number.parseFloat(supplyRaw.replace("%", "")))
      expect(row.borrowAprPct).toBe(Number.parseFloat(borrowRaw.replace("%", "")))
      expect(row.availableUsd).toBe(available)
      expect(row.collateralFactorPct).toBe(cf * 100)
      expect(row.liquidationThresholdPct).toBe(lt * 100)
      expect(row.iconUrl).toBe(logo)
    }
  })
})
