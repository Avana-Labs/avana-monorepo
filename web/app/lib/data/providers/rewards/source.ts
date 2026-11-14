import {
  createDataSourceAdapter,
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { api } from "@/convex/_generated/api"
import {
  REWARDS_PROMO_TABS,
  emptyRewardsQuestsByTab,
  imageForTask,
  resolveRewardsPromoTab,
  type RewardsQuestIconId,
} from "@/app/lib/data/rewards/catalog"
import { buildDefaultRewardsCatalog, evaluateAllTasksForUser } from "@/app/lib/rewards-engine"
import type { RewardsSessionState } from "@/app/lib/rewards-system/contracts"
import { getAuthenticatedConvexClient } from "@/app/lib/data/providers/live-convex-client"
import type { RewardsPageData } from "./types"

export type FetchRewardsPageInput = {
  walletProfileId: string
}

export type RewardsPageSource = {
  adapter: DataSourceAdapter
  getRewardsPageData(
    input: FetchRewardsPageInput,
    context?: DataSourceRequestContext,
  ): Promise<DataSourceResponse<RewardsPageData>>
}

const liveRewardsPageAdapter = createDataSourceAdapter({
  id: "rewards-live",
  label: "Rewards page live source",
  mode: "live",
})

const mockRewardsPageAdapter = createDataSourceAdapter({
  id: "rewards-mock",
  label: "Rewards page mock source",
  mode: "mock",
})

function buildRewardsPageData(wallet: string, state: RewardsSessionState): DataSourceResponse<RewardsPageData> {
  const now = Date.now()
  const tasks = buildDefaultRewardsCatalog(now)
  const progress = evaluateAllTasksForUser({
    tasks,
    wallet,
    events: state.events,
    claims: state.claims,
    now,
    firstLoginAt: state.firstLoginAt,
  })
  const progressByTask = new Map(progress.map((entry) => [entry.taskId, entry]))
  const iconForTag = (tag: string): RewardsQuestIconId => {
    if (tag === "lend") return "droplets"
    if (tag === "borrow") return "rocket"
    if (tag === "multiply") return "layers3"
    if (tag === "referral") return "link2"
    if (tag === "streak") return "flame"
    if (tag === "risk" || tag === "education") return "shieldCheck"
    if (tag === "mastery") return "trophy"
    return "wallet"
  }
  const questsByTab = tasks.reduce<RewardsPageData["questsByTab"]>((result, task) => {
    const tab = resolveRewardsPromoTab(task)
    const taskProgress = progressByTask.get(task.id)
    result[tab].push({
      id: task.id,
      title: task.title,
      description: task.description,
      reward: `${task.rewardAmount} ${task.rewardSymbol}`,
      cta: taskProgress?.status === "claimed" ? "Claimed" : task.actionLabel,
      category: task.tag,
      iconId: iconForTag(task.tag),
      image: imageForTask(task.id),
    })
    return result
  }, emptyRewardsQuestsByTab())

  return {
    fetchedAt: new Date().toISOString(),
    data: {
      walletProfileId: wallet,
      promoTabs: REWARDS_PROMO_TABS,
      questsByTab,
    },
  }
}

export const liveRewardsPageSource: RewardsPageSource = {
  adapter: liveRewardsPageAdapter,
  async getRewardsPageData(input) {
    const { client, wallet } = await getAuthenticatedConvexClient(liveRewardsPageAdapter.id, "getRewardsPageData")
    if (input.walletProfileId && input.walletProfileId.toLowerCase() !== wallet) {
      throw new Error("Requested rewards do not match the authenticated wallet.")
    }
    const stored = await client.query(api.sandbox.rewards.getState, { wallet })
    const state: RewardsSessionState = stored
      ? (JSON.parse(stored.stateJson) as RewardsSessionState)
      : {
          events: [],
          claims: [],
          referralProfiles: {},
          relationships: [],
          firstLoginAt: Date.now(),
          favoriteMarketIds: [],
        }
    return buildRewardsPageData(wallet, state)
  },
}

export const mockRewardsPageSource: RewardsPageSource = {
  adapter: mockRewardsPageAdapter,
  async getRewardsPageData(input) {
    return buildRewardsPageData(input.walletProfileId, {
      events: [],
      claims: [],
      referralProfiles: {},
      relationships: [],
      firstLoginAt: Date.now(),
      favoriteMarketIds: [],
    })
  },
}
