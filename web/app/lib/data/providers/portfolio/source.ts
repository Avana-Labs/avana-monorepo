import type {
  DataSourceAdapter,
  DataSourceRequestContext,
  DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import type { PortfolioPageRecords } from "./records"

export type * from "./records"

export type PortfolioPageSource = {
  adapter: DataSourceAdapter
  getDefaultWalletProfileId(context?: DataSourceRequestContext): string
  getPortfolioPageRecords(
    walletProfileId: string,
    context?: DataSourceRequestContext,
  ): Promise<DataSourceResponse<PortfolioPageRecords>>
}
