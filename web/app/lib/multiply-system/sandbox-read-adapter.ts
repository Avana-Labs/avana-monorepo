import type { MultiplySystemState } from "@/app/lib/multiply-engine"
import type { MultiplyReadAdapter } from "./contracts"
import { buildMultiplyPageData, buildMultiplyWalletSnapshot, buildPortfolioMultiplyData } from "./read-model"

export class SandboxMultiplyReadAdapter implements MultiplyReadAdapter {
  readonly mode = "sandbox" as const
  private readonly state: MultiplySystemState
  private readonly transactionHistory: Parameters<typeof buildMultiplyWalletSnapshot>[2]

  constructor({
    state,
    transactionHistory = [],
  }: {
    state: MultiplySystemState
    transactionHistory?: Parameters<typeof buildMultiplyWalletSnapshot>[2]
  }) {
    this.state = state
    this.transactionHistory = transactionHistory
  }

  async readWalletSnapshot(walletId: string) {
    return buildMultiplyWalletSnapshot(walletId, this.state, this.transactionHistory)
  }

  async readMarkets() {
    return Object.values(this.state.markets)
  }

  async readMultiplyPage(walletId: string) {
    return buildMultiplyPageData(walletId, this.state)
  }

  async readPortfolioMultiply(walletId: string, collateralPriceFor?: (symbol: string) => number | undefined) {
    return buildPortfolioMultiplyData(walletId, this.state, this.transactionHistory, collateralPriceFor)
  }
}
