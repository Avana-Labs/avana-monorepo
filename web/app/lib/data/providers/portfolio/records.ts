export type PortfolioActivityProduct = "borrow" | "pool" | "lend" | "rewards" | "swap"

export type PortfolioActivityKind =
  | "swap"
  | "supply"
  | "withdraw"
  | "borrow"
  | "repay"
  | "pledge"
  | "claim"
  | "stake"
  | "startCooldown"
  | "unstake"
  | "open"
  | "addCollateral"
  | "reduce"
  | "close"
  | "rebalance"
  | "interest"
  | "liquidation"

export type PortfolioActivityStatus = "confirmed" | "pending" | "failed"

export type PortfolioStrategyTone = "conservative" | "moderate" | "aggressive"

export type PortfolioWalletProfileRecord = {
  id: string
  walletAddress: string
}

export type PortfolioPoolVisualRecord = {
  symbol: string
  shortLabel: string
  bgClassName: string
  textClassName: string
}

export type PortfolioPoolRecord = {
  id: string
  name: string
  venue: string
  category: string
  collateralUsd: number
  maxLtv: number
  borrowPowerUsd: number
  liquidationUsd: number
  pairApr: number
  visuals: [PortfolioPoolVisualRecord, PortfolioPoolVisualRecord]
}

export type PortfolioSnapshotRecord = {
  walletProfileId: string
  timestamp: string
  totalValueUsd: number
  totalSuppliedUsd: number
  totalBorrowedUsd: number
  availableToBorrowUsd: number
  totalMultiplyExposureUsd: number
  totalEarnedUsd: number
}

export type PortfolioSupplyRecord = {
  id: string
  walletProfileId: string
  symbol: string
  name: string
  balance: number
  priceUsd: number
  suppliedUsd: number
  earnedUsd: number
  dailyEarnedUsd: number
  apyPct: number
}

export type PortfolioDebtRecord = {
  id: string
  walletProfileId: string
  poolId: string
  debtAssetSymbol: string
  borrowedUsd: number
  borrowAprPct: number
  accruedInterestUsd: number
  dailyInterestUsd: number
}

export type PortfolioCollateralRecord = {
  id: string
  walletProfileId: string
  pool: PortfolioPoolRecord
  borrowedUsd: number
  healthFactor: number | null
  pairApr: number
  feesUsd: number
}

export type PortfolioCreditLinesRecord = {
  walletProfileId: string
  approvedUsd: number
  liquidationThresholdUsd: number
  averageHealthFactor: number | null
  currentLtvPct: number
  totalBorrowedUsd: number
  totalCollateralUsd: number
}

export type PortfolioMultiplyCollateralRecord = {
  id: string
  walletProfileId: string
  label: string
  collateralToken: string
  borrowableToken: string
  multiplier: number
  protocol: string
  healthFactor: number
  collateralUsd: number
  borrowPowerUsd: number
}

export type PortfolioMultiplyPositionRecord = {
  id: string
  walletProfileId: string
  symbol: string
  label: string
  side: "long" | "short"
  leverage: number
  collateralUsd: number
  exposureUsd: number
  pnlUsd: number
  pnlPct: number
  status: "open" | "closed"
}

export type PortfolioOpenOrderRecord = {
  id: string
  walletProfileId: string
  label: string
  status: "open" | "pending" | "filled"
  sizeUsd: number
  venue: string
}

export type PortfolioTwapOrderRecord = {
  id: string
  walletProfileId: string
  label: string
  interval: string
  status: "active" | "paused" | "completed"
  amountUsd: number
}

export type PortfolioActivityRecord = {
  id: string
  walletProfileId: string
  at: string
  product: PortfolioActivityProduct
  kind: PortfolioActivityKind
  status: PortfolioActivityStatus
  amountUsd: number
  primaryLabel: string
  secondaryLabel: string
  txHash: string
  marketId?: string
}

export type PortfolioStrategyPoolRecord = {
  name: string
  apyPct: number
  tvlUsd: number
  isUp: boolean
  allocationUsd: number
}

export type PortfolioStrategyBucketRecord = {
  title: string
  description: string
  apyRangeLabel: string
  tone: PortfolioStrategyTone
  pools: PortfolioStrategyPoolRecord[]
}

export type PortfolioRewardsRecord = {
  walletProfileId: string
  claimableUsd: number
  earnedUsd: number
  settledUsd: number
  pendingUsd: number
}

export type PortfolioPageRecords = {
  walletProfile: PortfolioWalletProfileRecord
  snapshots: PortfolioSnapshotRecord[]
  supplies: PortfolioSupplyRecord[]
  debts: PortfolioDebtRecord[]
  collaterals: PortfolioCollateralRecord[]
  multiplyCreditLines: PortfolioCreditLinesRecord
  multiplyCollaterals: PortfolioMultiplyCollateralRecord[]
  multiplyPositions: PortfolioMultiplyPositionRecord[]
  openOrders: PortfolioOpenOrderRecord[]
  twapOrders: PortfolioTwapOrderRecord[]
  activity: PortfolioActivityRecord[]
  strategies: PortfolioStrategyBucketRecord[]
  rewards: PortfolioRewardsRecord
}
