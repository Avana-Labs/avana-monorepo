import { z } from "zod"
import { executeSourceLoad, type DataSourceRequestContext } from "@/app/lib/data/core/source-runtime"
import { resolveDataSourceMode } from "../source-mode"
import { liveMultiplyPageSource, mockMultiplyPageSource, type MultiplyPageSource } from "./source"
import type { MultiplyPageData } from "./types"

const multiplyPageSchema = z.object({
  markets: z.array(z.object({ symbol: z.string(), name: z.string(), price: z.number() }).passthrough()),
  // heroMetrics is a required field of MultiplyPageData; it MUST be listed here or
  // zod strips it from the validated response, leaving the hero with `undefined`
  // metrics on the pre-mount render (crashes MultiplyHero on metrics.marketCount).
  heroMetrics: z.object({
    totalLiquidityUsd: z.number(),
    marketCount: z.number(),
    averageMaxApy: z.number(),
    averageMaxLeverage: z.number(),
  }),
  lendRows: z.array(z.object({ protocol: z.string(), asset: z.string(), href: z.string() }).passthrough()),
  trendingSnapshots: z.array(
    z
      .object({
        marketId: z.string(),
        label: z.string(),
        href: z.string(),
      })
      .passthrough(),
  ),
  pageSize: z.number().int().positive(),
  tokenLogos: z.record(z.string(), z.string()),
})

function getMultiplyPageSource(source?: MultiplyPageSource) {
  if (source) return source
  const mode = resolveDataSourceMode()
  return mode === "mock" ? mockMultiplyPageSource : liveMultiplyPageSource
}

function getMultiplyPageFallback() {
  return undefined
}

export async function fetchMultiplyPage(
  source?: MultiplyPageSource,
  context?: DataSourceRequestContext,
): Promise<MultiplyPageData> {
  const response = await executeSourceLoad<MultiplyPageSource, unknown>({
    primary: getMultiplyPageSource(source),
    fallback: getMultiplyPageFallback(),
    operation: "getMultiplyPageData",
    context,
    schema: multiplyPageSchema,
    load: (pageSource, requestContext) =>
      pageSource.getMultiplyPageData(requestContext) as Promise<
        import("@/app/lib/data/core/source-runtime").DataSourceResponse<unknown>
      >,
  })

  return response.data as unknown as MultiplyPageData
}
