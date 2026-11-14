import type { BorrowSystemState } from "@/app/lib/credit-engine"
import type { TransactionHistoryItem } from "./contracts"
import type { SandboxReadAdapter } from "./contracts"
import {
  buildLegacyTransactionHistory,
  buildBorrowPageData,
  buildPortfolioBorrowData,
  buildWalletReadSnapshot,
  resolveAssetDetailFromState,
  resolvePoolDetailFromState,
} from "./read-model"

export class SandboxBorrowReadAdapter implements SandboxReadAdapter {
  readonly mode = "sandbox" as const
  private readonly state: BorrowSystemState
  private readonly transactionHistory?: TransactionHistoryItem[]

  constructor({
    state,
    transactionHistory,
  }: {
    state: BorrowSystemState
    transactionHistory?: TransactionHistoryItem[]
  }) {
    this.state = state
    this.transactionHistory = transactionHistory
  }

  async readWalletSnapshot(walletId: string) {
    return buildWalletReadSnapshot(
      this.state,
      walletId,
      this.transactionHistory ?? buildLegacyTransactionHistory(this.state, walletId),
    )
  }

  async readMarkets() {
    return Object.values(this.state.markets)
  }

  async readBorrowPage(walletId: string) {
    return buildBorrowPageData(this.state, walletId)
  }

  async readPortfolioBorrow(walletId: string) {
    return buildPortfolioBorrowData(this.state, walletId)
  }

  async readPoolDetail(poolId: string) {
    return resolvePoolDetailFromState(this.state, this.resolveWalletId(), poolId)
  }

  async readAssetDetail(assetId: string) {
    return resolveAssetDetailFromState(assetId)
  }

  private resolveWalletId() {
    return Object.keys(this.state.accounts)[0] ?? "demo-wallet"
  }
}
