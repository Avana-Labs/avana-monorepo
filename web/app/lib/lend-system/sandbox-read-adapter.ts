import type { LendReadAdapter } from "./contracts"
import { buildLendPageData, buildLendWalletSnapshot, buildPortfolioLendData } from "./read-model"
import type { LendSystemState } from "@/app/lib/lend-engine"
import type { LendTransactionHistoryItem } from "./contracts"

export class SandboxLendReadAdapter implements LendReadAdapter {
  readonly mode = "sandbox" as const

  constructor(
    private readonly source: {
      state: LendSystemState
      transactionHistory?: LendTransactionHistoryItem[]
    },
  ) {}

  async readWalletSnapshot(walletId: string) {
    return buildLendWalletSnapshot(walletId, this.source.state, this.source.transactionHistory ?? [])
  }

  async readMarkets() {
    return Object.values(this.source.state.markets)
  }

  async readLendPage(walletId: string) {
    return buildLendPageData(walletId, this.source.state)
  }

  async readPortfolioLend(walletId: string) {
    return buildPortfolioLendData(walletId, this.source.state, this.source.transactionHistory ?? [])
  }
}
