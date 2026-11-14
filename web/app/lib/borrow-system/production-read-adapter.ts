import type { AssetDetail, PoolDetail } from "@/app/lib/borrow-detail"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"
import type { BorrowMarketRecord } from "@/app/lib/borrow-system/model"
import type { ProductionReadAdapter, WalletReadSnapshot } from "./contracts"

const NOT_IMPLEMENTED = "BLOCKED: Production read adapter is not implemented"

export type ProductionBorrowReadSource = Partial<{
  readWalletSnapshot: (walletId: string) => Promise<WalletReadSnapshot>
  readMarkets: () => Promise<BorrowMarketRecord[]>
  readBorrowPage: (walletId: string) => Promise<BorrowPageData>
  readPortfolioBorrow: (walletId: string) => Promise<PortfolioBorrowTabData>
  readPoolDetail: (poolId: string) => Promise<PoolDetail | null>
  readAssetDetail: (assetId: string) => Promise<AssetDetail | null>
}>

export class ProductionBorrowReadAdapter implements ProductionReadAdapter {
  readonly mode = "production" as const

  constructor(private readonly source: ProductionBorrowReadSource = {}) {}

  async readWalletSnapshot(walletId: string): Promise<WalletReadSnapshot> {
    if (!this.source.readWalletSnapshot) throw new Error(NOT_IMPLEMENTED)
    return this.source.readWalletSnapshot(walletId)
  }

  async readMarkets(): Promise<BorrowMarketRecord[]> {
    if (!this.source.readMarkets) throw new Error(NOT_IMPLEMENTED)
    return this.source.readMarkets()
  }

  async readBorrowPage(walletId: string): Promise<BorrowPageData> {
    if (!this.source.readBorrowPage) throw new Error(NOT_IMPLEMENTED)
    return this.source.readBorrowPage(walletId)
  }

  async readPortfolioBorrow(walletId: string): Promise<PortfolioBorrowTabData> {
    if (!this.source.readPortfolioBorrow) throw new Error(NOT_IMPLEMENTED)
    return this.source.readPortfolioBorrow(walletId)
  }

  async readPoolDetail(poolId: string): Promise<PoolDetail | null> {
    if (!this.source.readPoolDetail) throw new Error(NOT_IMPLEMENTED)
    return this.source.readPoolDetail(poolId)
  }

  async readAssetDetail(assetId: string): Promise<AssetDetail | null> {
    if (!this.source.readAssetDetail) throw new Error(NOT_IMPLEMENTED)
    return this.source.readAssetDetail(assetId)
  }
}
