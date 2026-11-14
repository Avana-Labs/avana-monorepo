import type { BorrowAction, BorrowMarketRecord, BorrowSystemState } from "@/app/lib/credit-engine"
import type { AssetDetail, PoolDetail } from "@/app/lib/borrow-detail"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"

export type TransactionActionType = "deposit" | "borrow" | "repay" | "withdraw" | "liquidate" | "claim"
export type TransactionStatus = "idle" | "pending" | "success" | "failed"
export type TransactionRiskLabel = "safe" | "warning" | "danger"

export type TransactionMetricsSnapshot = {
  collateralValueUsd6: bigint
  borrowCapacityUsd6: bigint
  availableBorrowCapacityUsd6: bigint
  totalBorrowedUsd6: bigint
  currentLtvWad: bigint
  healthFactorWad: bigint | null
}

export type TransactionIntent = {
  id: string
  actionType: TransactionActionType
  walletId: string
  marketId?: string
  assetId?: string
  positionId?: string
  debtPositionId?: string
  amountUsd6: bigint
  requestedAt: number
  simulated: boolean
  payload?: BorrowAction
}

export type TransactionPreview = {
  intent: TransactionIntent
  allowed: boolean
  warnings: string[]
  validationErrors: string[]
  riskLabel: TransactionRiskLabel
  before: TransactionMetricsSnapshot
  after: TransactionMetricsSnapshot
}

export type TransactionResult = {
  id: string
  hash: string
  status: TransactionStatus
  actionType: TransactionActionType
  simulated: boolean
  timestamp: number
  explorerUrl?: string
  blockNumber?: number
  chainId?: number
  error?: string
}

export type SyntheticTransactionReceipt = TransactionResult

export type TransactionHistoryItem = {
  id: string
  intentId: string
  walletId: string
  marketId?: string
  assetId?: string
  kind: TransactionActionType
  status: TransactionStatus
  requestedAmountUsd6: bigint
  executedAmountUsd6: bigint
  simulated: boolean
  timestamp: number
  hash: string
}

export type SandboxActionResult = {
  preview: TransactionPreview
  receipt: SyntheticTransactionReceipt
  result: TransactionResult
  historyItem: TransactionHistoryItem
  state: BorrowSystemState
}

export type WalletReadSnapshot = {
  walletId: string
  transactionHistory: TransactionHistoryItem[]
  creditSnapshot: TransactionMetricsSnapshot
}

export type BaseReadAdapter = {
  mode: "sandbox" | "production"
  readWalletSnapshot(walletId: string): Promise<WalletReadSnapshot>
  readMarkets(): Promise<BorrowMarketRecord[]>
  readBorrowPage(walletId: string): Promise<BorrowPageData>
  readPortfolioBorrow(walletId: string): Promise<PortfolioBorrowTabData>
  readPoolDetail(poolId: string): Promise<PoolDetail | null>
  readAssetDetail(assetId: string): Promise<AssetDetail | null>
}

export type SandboxReadAdapter = BaseReadAdapter & {
  mode: "sandbox"
}

export type ProductionReadAdapter = BaseReadAdapter & {
  mode: "production"
}

export type TransactionAdapter = {
  mode: "sandbox" | "production"
  createIntent(action: BorrowAction): TransactionIntent
  previewTransaction(intent: TransactionIntent): Promise<TransactionPreview>
  executeTransaction(intent: TransactionIntent): Promise<SandboxActionResult>
}
