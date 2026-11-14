import type { MultiplyAction, MultiplyMarketRecord, MultiplySystemState } from "@/app/lib/multiply-engine"
import type { PortfolioMultiplyTabData } from "@/app/lib/data/providers/portfolio"
import type { MultiplyPageData } from "@/app/lib/data/providers/multiply"

export type MultiplyTransactionActionType = "multiply" | "deleverage" | "close"
export type MultiplyTransactionStatus = "idle" | "pending" | "success" | "failed"
export type MultiplyTransactionRiskLabel = "safe" | "warning" | "danger"

export type MultiplyTransactionIntent = {
  id: string
  actionType: MultiplyTransactionActionType
  walletId: string
  marketId?: string
  positionId?: string
  requestedAt: number
  simulated: boolean
  payload?: MultiplyAction
}

export type MultiplyMetricsSnapshot = {
  collateralValueUsd: number
  debtValueUsd: number
  multiplier: number
  ltv: number
  healthFactor: number | "infinity"
  netApy: number
}

export type MultiplyTransactionPreview = {
  intent: MultiplyTransactionIntent
  allowed: boolean
  warnings: string[]
  validationErrors: string[]
  riskLabel: MultiplyTransactionRiskLabel
  before: MultiplyMetricsSnapshot
  after: MultiplyMetricsSnapshot
  simulationSummary?: {
    liquidationPrice: number | null
    priceImpactPct: number
    maxLeverageApy?: number
    loopCount?: number
  }
}

export type MultiplyTransactionResult = {
  id: string
  hash: string
  status: MultiplyTransactionStatus
  actionType: MultiplyTransactionActionType
  simulated: boolean
  timestamp: number
  error?: string
}

export type MultiplyTransactionHistoryItem = {
  id: string
  intentId: string
  walletId: string
  marketId?: string
  positionId?: string
  kind: MultiplyTransactionActionType
  status: MultiplyTransactionStatus
  amountUsd: number
  multiplierBefore: number
  multiplierAfter: number
  simulated: boolean
  timestamp: number
  hash: string
}

export type MultiplySandboxActionResult = {
  preview: MultiplyTransactionPreview
  receipt: MultiplyTransactionResult
  historyItem: MultiplyTransactionHistoryItem
  state: MultiplySystemState
}

export type MultiplyRiskSnapshot = {
  marketId: string
  healthFactor: number | "infinity"
  ltv: number
  multiplier: number
  capturedAt: number
}

export type MultiplyWalletReadSnapshot = {
  walletId: string
  transactionHistory: MultiplyTransactionHistoryItem[]
  metrics: MultiplyMetricsSnapshot
  riskSnapshots: MultiplyRiskSnapshot[]
}

export type MultiplyReadAdapter = {
  mode: "sandbox" | "production"
  readWalletSnapshot(walletId: string): Promise<MultiplyWalletReadSnapshot>
  readMarkets(): Promise<MultiplyMarketRecord[]>
  readMultiplyPage(walletId: string): Promise<MultiplyPageData>
  readPortfolioMultiply(
    walletId: string,
    /** Live collateral-token price resolver so the tab values track the oracle like the headline. */
    collateralPriceFor?: (symbol: string) => number | undefined,
  ): Promise<PortfolioMultiplyTabData>
}

export type MultiplyTransactionAdapter = {
  mode: "sandbox" | "production"
  createIntent(action: MultiplyAction): MultiplyTransactionIntent
  previewTransaction(intent: MultiplyTransactionIntent): Promise<MultiplyTransactionPreview>
  executeTransaction(intent: MultiplyTransactionIntent): Promise<MultiplySandboxActionResult>
}
