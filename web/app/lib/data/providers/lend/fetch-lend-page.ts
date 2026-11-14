import { z } from "zod"
import { executeSourceLoad, type DataSourceRequestContext } from "@/app/lib/data/core/source-runtime"
import { liveLendPageSource, type LendPageSource } from "./source"
import type { LendPageData } from "./types"

const lendPageSchema = z.object({
  markets: z.array(z.object({ symbol: z.string(), name: z.string() }).passthrough()),
  featuredAssets: z.record(
    z.string(),
    z.object({
      id: z.string(),
      symbol: z.string(),
      displayName: z.string(),
      apy: z.number(),
      iconUrl: z.string(),
      path: z.string(),
    }),
  ),
  featuredSequence: z.array(z.string()),
  featuredSnapshots: z.array(
    z
      .object({
        marketId: z.string(),
        symbol: z.string(),
        href: z.string(),
      })
      .passthrough(),
  ),
  assetGroups: z.array(
    z.object({
      title: z.string(),
      subtitle: z.string().optional(),
      rows: z.array(z.object({ symbol: z.string(), name: z.string(), apy: z.string() }).passthrough()),
    }),
  ),
})

function getLendPageSource(source?: LendPageSource) {
  return source ?? liveLendPageSource
}

function getLendPageFallback() {
  return undefined
}

export async function fetchLendPage(
  source?: LendPageSource,
  context?: DataSourceRequestContext,
): Promise<LendPageData> {
  const response = await executeSourceLoad<LendPageSource, unknown>({
    primary: getLendPageSource(source),
    fallback: getLendPageFallback(),
    operation: "getLendPageData",
    context,
    schema: lendPageSchema,
    load: (pageSource, requestContext) =>
      pageSource.getLendPageData(requestContext) as Promise<
        import("@/app/lib/data/core/source-runtime").DataSourceResponse<unknown>
      >,
  })

  return response.data as unknown as LendPageData
}
