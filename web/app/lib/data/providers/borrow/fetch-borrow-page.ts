import { z } from "zod"
import { executeSourceLoad, type DataSourceRequestContext } from "@/app/lib/data/core/source-runtime"
import { resolveDataSourceMode } from "../source-mode"
import { liveBorrowPageSource, mockBorrowPageSource, type BorrowPageSource } from "./source"
import type { BorrowPageData } from "./types"

const borrowPageSchema = z.object({
  walletId: z.string(),
  borrowSessionSeed: z.string(),
  poolCatalog: z.array(z.object({ id: z.string(), name: z.string() }).passthrough()),
  heroMetrics: z.object({
    totalTvlUsd: z.number(),
    totalCollateralUsd: z.number(),
    availableCreditUsd: z.number(),
    outstandingLoansUsd: z.number(),
    totalTvlChangePct: z.number(),
  }),
  borrowableAssets: z.array(z.object({ id: z.string(), symbol: z.string() }).passthrough()),
  pendingRows: z.array(z.object({}).passthrough()),
  dexes: z.array(z.object({ id: z.string() }).passthrough()),
  collateralPools: z.array(z.object({ id: z.string(), name: z.string() }).passthrough()),
  initialDebts: z.record(z.string(), z.number()),
  borrowSnapshot: z.object({
    totalBorrowedUsd: z.number(),
    availableCreditUsd: z.number(),
    totalCollateralUsd: z.number(),
    liquidationValueUsd: z.number(),
    healthFactor: z.number().nullable(),
  }),
})

function getBorrowPageSource(source?: BorrowPageSource) {
  if (source) return source
  const mode = resolveDataSourceMode()
  return mode === "mock" ? mockBorrowPageSource : liveBorrowPageSource
}

function getBorrowPageFallback() {
  return undefined
}

export async function fetchBorrowPage(
  source?: BorrowPageSource,
  context?: DataSourceRequestContext,
): Promise<BorrowPageData> {
  const response = await executeSourceLoad<BorrowPageSource, unknown>({
    primary: getBorrowPageSource(source),
    fallback: getBorrowPageFallback(),
    operation: "getBorrowPageData",
    context,
    schema: borrowPageSchema,
    load: (pageSource, requestContext) =>
      pageSource.getBorrowPageData(requestContext) as Promise<
        import("@/app/lib/data/core/source-runtime").DataSourceResponse<unknown>
      >,
  })

  return response.data as unknown as BorrowPageData
}
