import type { ChartRangeData } from "@/app/components/charts"
import type { DataSourcePageInfo } from "@/app/lib/data/core/source-runtime"
import type {
  PortfolioActivityKind,
  PortfolioActivityProduct,
  PortfolioActivityStatus,
  PortfolioStrategyTone,
} from "./records"

export type PortfolioTabKey = "overview" | "lending" | "activity"

export type FetchPortfolioPageInput = {
  walletProfileId: string
}

export type PortfolioWalletProfile = {
  id: string
  walletAddress: string
}

export type PortfolioHeroData = {
  headlineValue?: string
  headlineDelta?: string
  rangeData?: ChartRangeData
  statOneValue?: string
  statTwoValue?: string
}

export type PortfolioTabSummary = {
  borrow: {
    totalCollateralUsd: number
    totalDebtUsd: number
    availableToBorrowUsd: number
    averageHealthFactor: number | null
  }
  lend: {
    totalSuppliedUsd: number
    totalEarnedUsd: number
    averageApyPct: number
  }
  activity: {
    totalEvents: number
  }
}

export type PortfolioBorrowTabData = {
  creditLines: {
    approvedUsd: number
    liquidationThresholdUsd: number
    averageHealthFactor: number | null
    currentLtvPct: number
    totalBorrowedUsd: number
    totalCollateralUsd: number
  }
  collateralPositions: Array<{
    pool: PortfolioPool
    borrowedUsd: number
    remainingBorrowPowerUsd: number
    liquidationThresholdUsd: number
    healthFactor: number | null
    pairApr: number
    feesUsd: number
    feesLabel: string
  }>
  debtPositions: Array<{
    id: string
    pool: PortfolioPool
    debtAssetSymbol: string
    borrowedUsd: number
    liquidationThresholdUsd: number
    healthFactor: number | null
    borrowApr: number
    accruedInterestUsd: number
    dailyInterestUsd: number
  }>
}

export type PortfolioSupplyPosition = {
  id: string
  marketId?: string
  symbol: string
  name: string
  balance: number
  priceUsd: number
  suppliedUsd: number
  principalUsd?: number
  earnedUsd: number
  dailyEarnedUsd: number
  apyPct: number
  principalAmount?: number
  interestEarned?: number
  interestUsd?: number
  rewardsEarnedUsd?: number
  availableToWithdraw?: number
  walletBalance?: number
  status?: "active" | "closed"
}

export type PortfolioPoolVisual = {
  symbol: string
  shortLabel: string
  bgClassName: string
  textClassName: string
}

export type PortfolioPool = {
  id: string
  name: string
  venue: string
  category: string
  collateralUsd: number
  maxLtv: number
  borrowPowerUsd: number
  liquidationUsd: number
  pairApr: number
  visuals: [PortfolioPoolVisual, PortfolioPoolVisual]
}

export type PortfolioStrategyPool = {
  name: string
  apyPct: number
  tvlUsd: number
  isUp: boolean
  allocationUsd: number
}

export type PortfolioStrategyBucket = {
  title: string
  description: string
  apyRangeLabel: string
  tone: PortfolioStrategyTone
  pools: PortfolioStrategyPool[]
}

export type PortfolioLendTabData = {
  investments: PortfolioSupplyPosition[]
  positions: PortfolioSupplyPosition[]
  strategyBuckets: PortfolioStrategyBucket[]
  history: PortfolioActivityRow[]
  rewardsSummary?: {
    claimableUsd: number
    totalEarnedUsd: number
  }
}

export type PortfolioActivityRow = {
  id: string
  at: string
  product: PortfolioActivityProduct
  kind: PortfolioActivityKind
  status: PortfolioActivityStatus
  amountUsd: number
  primaryLabel: string
  secondaryLabel: string
  txHash: string
  /** Stable action-market identity used to deduplicate persisted/session copies. */
  marketId?: string
}

export type PortfolioActivityData = {
  rows: PortfolioActivityRow[]
  pageInfo?: DataSourcePageInfo
}

export type PortfolioRewardsData = {
  claimableUsd: number
  earnedUsd: number
  settledUsd: number
  pendingUsd: number
}

export type PortfolioPageData = {
  walletProfile: PortfolioWalletProfile
  fetchedAt: string
  heroByTab: Record<PortfolioTabKey, PortfolioHeroData>
  tabs: PortfolioTabSummary
  borrow: PortfolioBorrowTabData
  lend: PortfolioLendTabData
  activity: PortfolioActivityData
  rewards: PortfolioRewardsData
}
