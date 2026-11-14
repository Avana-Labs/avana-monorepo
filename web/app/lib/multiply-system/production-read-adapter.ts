import type { MultiplyMarketRecord } from "@/app/lib/multiply-engine"
import type { MultiplyPageData } from "@/app/lib/data/providers/multiply"
import type { PortfolioMultiplyTabData } from "@/app/lib/data/providers/portfolio"
import type { MultiplyReadAdapter, MultiplyWalletReadSnapshot } from "./contracts"

const NOT_IMPLEMENTED = "BLOCKED: Production multiply read adapter is not implemented"

export type ProductionMultiplyReadSource = Partial<{
  readWalletSnapshot: (walletId: string) => Promise<MultiplyWalletReadSnapshot>
  readMarkets: () => Promise<MultiplyMarketRecord[]>
  readMultiplyPage: (walletId: string) => Promise<MultiplyPageData>
  readPortfolioMultiply: (walletId: string) => Promise<PortfolioMultiplyTabData>
}>

export class ProductionMultiplyReadAdapter implements MultiplyReadAdapter {
  readonly mode = "production" as const

  constructor(private readonly source: ProductionMultiplyReadSource = {}) {}

  async readWalletSnapshot(walletId: string): Promise<MultiplyWalletReadSnapshot> {
    if (!this.source.readWalletSnapshot) throw new Error(NOT_IMPLEMENTED)
    return this.source.readWalletSnapshot(walletId)
  }

  async readMarkets(): Promise<MultiplyMarketRecord[]> {
    if (!this.source.readMarkets) throw new Error(NOT_IMPLEMENTED)
    return this.source.readMarkets()
  }

  async readMultiplyPage(walletId: string): Promise<MultiplyPageData> {
    if (!this.source.readMultiplyPage) throw new Error(NOT_IMPLEMENTED)
    return this.source.readMultiplyPage(walletId)
  }

  async readPortfolioMultiply(walletId: string): Promise<PortfolioMultiplyTabData> {
    if (!this.source.readPortfolioMultiply) throw new Error(NOT_IMPLEMENTED)
    return this.source.readPortfolioMultiply(walletId)
  }
}
