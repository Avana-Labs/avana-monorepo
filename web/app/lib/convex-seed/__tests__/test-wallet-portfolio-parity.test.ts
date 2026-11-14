import { describe, expect, it } from "vitest"
import {
  TEST_WALLET_COLLATERAL_SEED_ROWS,
  TEST_WALLET_DEBTS_SEED_ROWS,
  TEST_WALLET_CLAIMS_SEED_ROWS,
} from "../inputs/test-wallet-portfolio-seed"
import { TEST_WALLET_ADDRESS } from "../build-seed"
import { HOME_COLLATERAL_POOLS, HOME_CLAIM_POSITIONS } from "@/app/lib/home-sim"
import { HOME_POOL_TO_MARKET_ID, HOME_POOL_TO_DEBT_ASSET_ID } from "@/app/lib/borrow-system/mock"

// The original `HOME_INITIAL_DEBTS` constant was deleted alongside its lone runtime
// consumer (mock.ts's initial-debt injection). The Convex seed rows are still asserted
// against those values here so a change to either the seed or the historical baseline
// is caught by parity, without keeping a dead export around just for tests.
const HISTORICAL_HOME_INITIAL_DEBTS: Record<string, number> = {
  "eth-usdc": 1_200,
  "usdc-usdt": 800,
  "wbtc-eth": 0,
}

describe("test-wallet portfolio seed parity", () => {
  it("test-wallet collateral positions match HOME_COLLATERAL_POOLS", () => {
    expect(TEST_WALLET_COLLATERAL_SEED_ROWS).toHaveLength(3)

    for (const row of TEST_WALLET_COLLATERAL_SEED_ROWS) {
      expect(row.wallet).toBe(TEST_WALLET_ADDRESS)

      const mock = HOME_COLLATERAL_POOLS.find((pool) => pool.id === row.homePoolId)
      expect(mock, `HOME_COLLATERAL_POOLS entry for ${row.homePoolId}`).toBeDefined()
      if (!mock) return

      expect(row.marketId).toBe(HOME_POOL_TO_MARKET_ID[row.homePoolId])
      expect(row.name).toBe(mock.name)
      expect(row.venueLabel).toBe(mock.venue)
      expect(row.category).toBe(mock.category)
      expect(row.collateralUsd).toBe(mock.collateralUsd)
      expect(row.borrowPowerUsd).toBe(mock.borrowPowerUsd)
      expect(row.liquidationUsd).toBe(mock.liquidationUsd)
      expect(row.maxLtvPct).toBe(mock.maxLtv)
      expect(row.pairAprPct).toBe(mock.pairApr)
    }
  })

  it("test-wallet debts match the historical HOME_INITIAL_DEBTS baseline", () => {
    expect(TEST_WALLET_DEBTS_SEED_ROWS).toHaveLength(2)

    for (const row of TEST_WALLET_DEBTS_SEED_ROWS) {
      expect(row.wallet).toBe(TEST_WALLET_ADDRESS)
      expect(row.debtAssetId).toBe(HOME_POOL_TO_DEBT_ASSET_ID[row.homePoolId])
      expect(row.amountUsd).toBe(HISTORICAL_HOME_INITIAL_DEBTS[row.homePoolId])
    }
  })

  it("test-wallet claim positions match HOME_CLAIM_POSITIONS", () => {
    expect(TEST_WALLET_CLAIMS_SEED_ROWS).toHaveLength(3)

    for (const row of TEST_WALLET_CLAIMS_SEED_ROWS) {
      expect(row.wallet).toBe(TEST_WALLET_ADDRESS)

      const mock = HOME_CLAIM_POSITIONS.find((position) => position.id === row.claimId)
      expect(mock, `HOME_CLAIM_POSITIONS entry for ${row.claimId}`).toBeDefined()
      if (!mock) return

      expect(row.claimId).toBe(mock.id)
      expect(row.homePoolId).toBe(mock.poolId)
      expect(row.name).toBe(mock.name)
      expect(row.subtitle).toBe(mock.subtitle)
      expect(row.totalUsd).toBe(mock.totalUsd)
      expect(row.marketId).toBe(HOME_POOL_TO_MARKET_ID[row.homePoolId])

      expect(row.breakdown).toHaveLength(mock.breakdown.length)
      for (let i = 0; i < mock.breakdown.length; i++) {
        const seedItem = row.breakdown[i]
        const mockItem = mock.breakdown[i]
        expect(seedItem.symbol).toBe(mockItem.symbol)
        expect(seedItem.amountLabel).toBe(mockItem.amountLabel)
        expect(seedItem.usdValue).toBe(mockItem.usdValue)
      }
    }
  })
})
