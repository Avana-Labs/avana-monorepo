import type { TransactionPreview } from "@/app/lib/borrow-system/contracts"
import type { LendTransactionPreview } from "@/app/lib/lend-system/contracts"
import type { MultiplyTransactionPreview } from "@/app/lib/multiply-system/contracts"

const usd6 = (value: number) => BigInt(Math.round(value * 1_000_000))
const wad = (value: number) => BigInt(Math.round(value * 1e18))

export function borrowPreviewFixture(overrides: Partial<TransactionPreview> = {}): TransactionPreview {
  const before = {
    collateralValueUsd6: usd6(10_000),
    borrowCapacityUsd6: usd6(7_500),
    availableBorrowCapacityUsd6: usd6(5_000),
    totalBorrowedUsd6: usd6(2_500),
    currentLtvWad: wad(0.25),
    healthFactorWad: wad(2.4),
  }
  const after = {
    collateralValueUsd6: usd6(10_000),
    borrowCapacityUsd6: usd6(7_500),
    availableBorrowCapacityUsd6: usd6(4_000),
    totalBorrowedUsd6: usd6(3_500),
    currentLtvWad: wad(0.35),
    healthFactorWad: wad(1.8),
  }

  return {
    intent: {
      id: "intent-1",
      actionType: "borrow",
      walletId: "wallet-1",
      marketId: "market-1",
      assetId: "usdc",
      amountUsd6: usd6(1_000),
      requestedAt: Date.now(),
      simulated: true,
    },
    allowed: true,
    warnings: [],
    validationErrors: [],
    riskLabel: "warning",
    before,
    after,
    ...overrides,
  }
}

export function lendPreviewFixture(overrides: Partial<LendTransactionPreview> = {}): LendTransactionPreview {
  const before = {
    suppliedAmount: 100,
    suppliedValueUsd: 100,
    principalAmount: 95,
    interestEarned: 5,
    rewardsEarnedUsd: 2,
    totalEarnedUsd: 7,
    currentApy: 4.2,
  }
  const after = {
    suppliedAmount: 150,
    suppliedValueUsd: 150,
    principalAmount: 142.5,
    interestEarned: 7.5,
    rewardsEarnedUsd: 3,
    totalEarnedUsd: 10.5,
    currentApy: 4.2,
  }

  return {
    intent: {
      id: "lend-intent-1",
      actionType: "deposit",
      walletId: "wallet-1",
      marketId: "gho",
      requestedAt: Date.now(),
      simulated: true,
    },
    allowed: true,
    warnings: [],
    validationErrors: [],
    before,
    after,
    ...overrides,
  }
}

export function multiplyPreviewFixture(
  overrides: Partial<MultiplyTransactionPreview> = {},
): MultiplyTransactionPreview {
  const before = {
    collateralValueUsd: 10_000,
    debtValueUsd: 5_000,
    multiplier: 2,
    ltv: 0.5,
    healthFactor: 1.9,
    netApy: 6.5,
  }
  const after = {
    collateralValueUsd: 12_000,
    debtValueUsd: 7_500,
    multiplier: 2.5,
    ltv: 0.62,
    healthFactor: 1.55,
    netApy: 8.1,
  }

  return {
    intent: {
      id: "multiply-intent-1",
      actionType: "multiply",
      walletId: "wallet-1",
      marketId: "weth-usdc",
      requestedAt: Date.now(),
      simulated: true,
    },
    allowed: true,
    warnings: [],
    validationErrors: [],
    riskLabel: "warning",
    before,
    after,
    simulationSummary: {
      liquidationPrice: 1_850,
      priceImpactPct: 0.12,
      loopCount: 2,
    },
    ...overrides,
  }
}
