import type { LendMarket } from "@/app/lib/lend-engine"
import type { LendPageData } from "@/app/lib/data/providers/lend/types"
import type { PortfolioLendTabData } from "@/app/lib/data/providers/portfolio/types"
import type { LendReadAdapter, LendWalletReadSnapshot } from "./contracts"

const NOT_IMPLEMENTED = "BLOCKED: Production lend read adapter is not implemented"

type ProductionLendReadAdapterOptions = Partial<{
  readWalletSnapshot: (walletId: string) => Promise<LendWalletReadSnapshot>
  readMarkets: () => Promise<LendMarket[]>
  readLendPage: (walletId: string) => Promise<LendPageData>
  readPortfolioLend: (walletId: string) => Promise<PortfolioLendTabData>
}>

export class ProductionLendReadAdapter implements LendReadAdapter {
  readonly mode = "production" as const

  constructor(private readonly source: ProductionLendReadAdapterOptions = {}) {}

  async readWalletSnapshot(walletId: string): Promise<LendWalletReadSnapshot> {
    if (!this.source.readWalletSnapshot) throw new Error(NOT_IMPLEMENTED)
    return this.source.readWalletSnapshot(walletId)
  }

  async readMarkets(): Promise<LendMarket[]> {
    if (!this.source.readMarkets) throw new Error(NOT_IMPLEMENTED)
    return this.source.readMarkets()
  }

  async readLendPage(walletId: string): Promise<LendPageData> {
    if (!this.source.readLendPage) throw new Error(NOT_IMPLEMENTED)
    return this.source.readLendPage(walletId)
  }

  async readPortfolioLend(walletId: string): Promise<PortfolioLendTabData> {
    if (!this.source.readPortfolioLend) throw new Error(NOT_IMPLEMENTED)
    return this.source.readPortfolioLend(walletId)
  }
}
