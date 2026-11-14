import { z } from "zod"
import { executeSourceLoad, type DataSourceRequestContext } from "@/app/lib/data/core/source-runtime"
import {
  liveRewardsPageSource,
  mockRewardsPageSource,
  type FetchRewardsPageInput,
  type RewardsPageSource,
} from "./source"
import { resolveDataSourceMode } from "../source-mode"
import type { RewardsPageData } from "./types"

const rewardsPageSchema = z.object({
  walletProfileId: z.string(),
  promoTabs: z.array(z.object({ id: z.string(), label: z.string() })),
  questsByTab: z.record(
    z.string(),
    z.array(
      z
        .object({
          id: z.string(),
          title: z.string(),
          description: z.string(),
          reward: z.string(),
          cta: z.string(),
          category: z.string(),
        })
        .passthrough(),
    ),
  ),
})

export async function fetchRewardsPage(
  input: FetchRewardsPageInput,
  source?: RewardsPageSource,
  context?: DataSourceRequestContext,
): Promise<RewardsPageData> {
  const primarySource = source ?? (resolveDataSourceMode() === "mock" ? mockRewardsPageSource : liveRewardsPageSource)
  const response = await executeSourceLoad<RewardsPageSource, unknown>({
    primary: primarySource,
    operation: "getRewardsPageData",
    context,
    schema: rewardsPageSchema,
    load: (resolvedSource, requestContext) =>
      resolvedSource.getRewardsPageData(input, requestContext) as Promise<
        import("@/app/lib/data/core/source-runtime").DataSourceResponse<unknown>
      >,
  })
  return response.data as unknown as RewardsPageData
}

export type { FetchRewardsPageInput }
