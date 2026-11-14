import type { LendAction, LendMarket, LendSystemState } from "@/app/lib/lend-system/model"
import type { LendPageData } from "@/app/lib/data/providers/lend/types"
import type { PortfolioLendTabData } from "@/app/lib/data/providers/portfolio/types"

export type LendTransactionActionType = "deposit" | "withdraw" | "claim"
export type LendTransactionStatus = "idle" | "pending" | "success" | "failed"

export type LendTransactionIntent = {
  id: string
  actionType: LendTransactionActionType
  walletId: string
  marketId: string
  positionId?: string
  requestedAt: number
  simulated: boolean
  payload?: LendAction
}

export type LendPositionMetricsSnapshot = {
  suppliedAmount: number
  suppliedValueUsd: number
  principalAmount: number
  interestEarned: number
  rewardsEarnedUsd: number
  totalEarnedUsd: number
  currentApy: number
}

export type LendTransactionPreview = {
  intent: LendTransactionIntent
  allowed: boolean
  warnings: string[]
  validationErrors: string[]
  before: LendPositionMetricsSnapshot
  after: LendPositionMetricsSnapshot
  maxWithdrawable?: number
}

export type LendTransactionResult = {
  id: string
  hash: string
  status: LendTransactionStatus
  actionType: LendTransactionActionType
  simulated: boolean
  timestamp: number
  error?: string
}

export type LendTransactionHistoryItem = {
  id: string
  intentId: string
  walletId: string
  marketId: string
  positionId?: string
  kind: LendTransactionActionType
  status: LendTransactionStatus
  asset: string
  amount: number
  /** USD recorded with the transaction; absent until the server row is hydrated. */
  amountUsd?: number
  simulated: boolean
  timestamp: number
  hash: string
}

export type LendActionResult = {
  preview: LendTransactionPreview
  receipt: LendTransactionResult
  historyItem: LendTransactionHistoryItem
  state: LendSystemState
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

export type LendWalletReadSnapshot = {
  walletId: string
  transactionHistory: LendTransactionHistoryItem[]
  metrics: LendPositionMetricsSnapshot
  yieldSnapshots: LendYieldSnapshot[]
}

export type LendReadAdapter = {
  mode: "production"
  readWalletSnapshot(walletId: string): Promise<LendWalletReadSnapshot>
  readMarkets(): Promise<LendMarket[]>
  readLendPage(walletId: string): Promise<LendPageData>
  readPortfolioLend(walletId: string): Promise<PortfolioLendTabData>
}

export type LendTransactionAdapter = {
  mode: "production"
  createIntent(action: LendAction): LendTransactionIntent
  previewTransaction(intent: LendTransactionIntent): Promise<LendTransactionPreview>
  executeTransaction(intent: LendTransactionIntent): Promise<LendActionResult>
}
