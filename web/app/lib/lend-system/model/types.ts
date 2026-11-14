export type LendRiskTier = "low" | "medium" | "high"

/** Market grouping for display + the Convex `category` column. Tokenized equities are "stock". */
export type LendMarketCategory = "stable" | "crypto" | "stock"

export type LendMarketStatus = "active" | "capped" | "paused"

export type LendAsset = {
  symbol: string
  name: string
  priceUsd: number
  decimals?: number
}

export type LendMarket = {
  marketId: string
  chainId: number
  rank: number
  asset: LendAsset
  assetPriceUsd: number
  supplyApy: number
  rewardsApy: number
  totalApy: number
  totalSupplied: number
  totalBorrowed: number
  availableLiquidity: number
  utilization: number
  reserveFactor: number
  supplyCap?: number
  status: LendMarketStatus
  riskTier: LendRiskTier
  /** Display/seed grouping (stable / crypto / stock). Optional so legacy constructors stay valid. */
  category?: LendMarketCategory
  liquidityIndex: number
  lastAccrualTimestamp: number
  priceUpdatedAt: number
}

export type LendPositionStatus = "active" | "closed"

export type LendPosition = {
  positionId: string
  walletId: string
  marketId: string
  asset: string
  principalAmount: number
  scaledBalance: number
  liquidityIndexAtLastAction: number
  currentSuppliedAmount: number
  interestEarned: number
  rewardsEarnedUsd: number
  suppliedValueUsd: number
  openedAt: number
  updatedAt: number
  status: LendPositionStatus
}

type LendTransactionKind = "deposit" | "withdraw" | "claim"

export type LendTransaction = {
  id: string
  walletId: string
  marketId: string
  kind: LendTransactionKind
  asset: string
  amount: number
  at: number
}

export type LendSystemState = {
  now: number
  markets: Record<string, LendMarket>
  positions: Record<string, LendPosition>
  walletBalances: Record<string, Record<string, number>>
  transactions: LendTransaction[]
}

export type LendDepositIntent = {
  type: "deposit"
  walletId: string
  marketId: string
  depositAmount: number
  walletBalance?: number
  at?: number
}

export type LendWithdrawIntent = {
  type: "withdraw"
  walletId: string
  marketId: string
  positionId: string
  withdrawAmount: number
  at?: number
}

export type LendClaimRewardsIntent = {
  type: "claim"
  walletId: string
  at?: number
}

export type LendAction = LendDepositIntent | LendWithdrawIntent | LendClaimRewardsIntent

export type LendValidationResult = {
  allowed: boolean
  errors: string[]
  warnings: string[]
}

export type LendPositionMetrics = {
  suppliedAmount: number
  suppliedValueUsd: number
  principalAmount: number
  interestEarned: number
  rewardsEarnedUsd: number
  totalEarnedUsd: number
  scaledBalance: number
  liquidityIndex: number
}

export type LendYieldSnapshot = {
  marketId: string
  asset: string
  supplyApy: number
  rewardsApy: number
  totalApy: number
  utilization: number
  availableLiquidity: number
  totalSupplied: number
  capturedAt: number
}

export type LendDepositSimulation = {
  action: "deposit"
  input: {
    marketId: string
    assetSymbol: string
    depositAmount: number
  }
  before: LendPositionMetrics
  after: LendPositionMetrics
  market: {
    supplyApy: number
    rewardsApy: number
    totalApy: number
    utilization: number
    availableLiquidity: number
    totalSupplied: number
    supplyCap?: number
  }
  marketBefore: {
    totalSupplied: number
    availableLiquidity: number
    utilization: number
  }
  marketAfter: {
    totalSupplied: number
    availableLiquidity: number
    utilization: number
  }
  validation: LendValidationResult
}

export type LendWithdrawSimulation = {
  action: "withdraw"
  input: {
    marketId: string
    assetSymbol: string
    withdrawAmount: number
  }
  before: LendPositionMetrics
  after: LendPositionMetrics
  withdrawal: {
    withdrawAmount: number
    withdrawValueUsd: number
    principalWithdrawn: number
    interestWithdrawn: number
    maxWithdrawable: number
  }
  market: {
    supplyApy: number
    rewardsApy: number
    totalApy: number
    utilization: number
    availableLiquidity: number
    totalSupplied: number
  }
  marketBefore: {
    totalSupplied: number
    availableLiquidity: number
    utilization: number
  }
  marketAfter: {
    totalSupplied: number
    availableLiquidity: number
    utilization: number
  }
  validation: LendValidationResult
}

export type LendTransactionResult = {
  id: string
  syntheticTxHash: string
  actionType: LendTransactionKind
  product: "lend"
  walletId: string
  marketId: string
  asset: string
  amount: number
  status: "success" | "failed"
  simulated: true
  timestamp: number
  before: LendPositionMetrics
  after: LendPositionMetrics
  warnings: string[]
}
