import {
  executeSourceLoad,
  normalizeDataSourceError,
  type DataSourceRequestContext,
} from "@/app/lib/data/core/source-runtime"
import { mockPortfolioPageSource } from "@/app/lib/data/mock/wallet/portfolio/source"
import { resolveDefaultWithAuthFallback } from "@/app/lib/data/providers/live-auth-fallback"
import { resolveDataSourceMode } from "../source-mode"
import { mapPortfolioPage } from "./map-portfolio-page"
import type { PortfolioPageSource } from "./source"
import type { FetchPortfolioPageInput, PortfolioPageData } from "./types"

type FetchOptions = {
  signal?: AbortSignal
  source?: PortfolioPageSource
  cursor?: DataSourceRequestContext["cursor"]
  limit?: number
}

async function loadFromSource(
  source: PortfolioPageSource,
  input: FetchPortfolioPageInput,
  options?: FetchOptions,
): Promise<PortfolioPageData> {
  const response = await executeSourceLoad({
    primary: source,
    fallback: undefined,
    operation: "getPortfolioPageRecords",
    context: { signal: options?.signal, cursor: options?.cursor, limit: options?.limit },
    load: (pageSource, requestContext) => pageSource.getPortfolioPageRecords(input.walletProfileId, requestContext),
  })
  const pageData = mapPortfolioPage(response.data)
  return {
    ...pageData,
    fetchedAt: response.fetchedAt ?? pageData.fetchedAt,
    activity: { ...pageData.activity, pageInfo: response.pageInfo },
  }
}

export async function fetchPortfolioPage(
  input: FetchPortfolioPageInput,
  options?: FetchOptions,
): Promise<PortfolioPageData> {
  if (options?.source) return loadFromSource(options.source, input, options)
  if (resolveDataSourceMode() === "mock") return loadFromSource(mockPortfolioPageSource, input, options)
  const { livePortfolioPageSource } = await import("./live-source")
  return loadFromSource(livePortfolioPageSource, input, options)
}

export async function resolvePortfolioWalletProfileId(source?: PortfolioPageSource) {
  const primarySource =
    source ??
    (resolveDataSourceMode() === "mock"
      ? mockPortfolioPageSource
      : (await import("./live-source")).livePortfolioPageSource)
  return resolveDefaultWithAuthFallback({
    allowFallback: !source,
    loadPrimary: () => {
      try {
        return primarySource.getDefaultWalletProfileId()
      } catch (error) {
        throw normalizeDataSourceError(error, primarySource.adapter, "getDefaultWalletProfileId")
      }
    },
    loadFallback: () => mockPortfolioPageSource.getDefaultWalletProfileId(),
  })
}

export type { FetchPortfolioPageInput, PortfolioPageData, PortfolioTabKey } from "./types"
