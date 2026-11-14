import {
  buildDefaultRewardsCatalog,
  calculateRewardSummary,
  evaluateAllTasksForUser,
  type RewardTask,
} from "@/app/lib/rewards-engine"
import type { RewardsReadAdapter } from "./contracts"
import type { RewardsSessionState } from "./contracts"

export class SandboxRewardsReadAdapter implements RewardsReadAdapter {
  readonly mode = "sandbox" as const
  private readonly tasks: RewardTask[]
  private readonly getState: () => RewardsSessionState

  constructor(
    private readonly source: {
      state: RewardsSessionState | (() => RewardsSessionState)
      now?: () => number
      tasks?: RewardTask[]
    },
  ) {
    this.tasks = source.tasks ?? buildDefaultRewardsCatalog((source.now ?? Date.now)())
    if (typeof source.state === "function") {
      this.getState = source.state
    } else {
      const snapshot = source.state
      this.getState = () => snapshot
    }
  }

  async readTasks() {
    return this.tasks
  }

  async readProgress(wallet: string) {
    const state = this.getState()
    return evaluateAllTasksForUser({
      tasks: this.tasks,
      wallet,
      events: state.events,
      claims: state.claims,
      now: (this.source.now ?? Date.now)(),
      firstLoginAt: state.firstLoginAt,
    })
  }

  async readRewardSummary(wallet: string) {
    const state = this.getState()
    return calculateRewardSummary({
      tasks: this.tasks,
      wallet,
      events: state.events,
      claims: state.claims,
      now: (this.source.now ?? Date.now)(),
      firstLoginAt: state.firstLoginAt,
    })
  }

  async readReferralProfile(wallet: string) {
    return this.getState().referralProfiles[wallet] ?? null
  }

  async readClaimHistory(wallet: string) {
    return this.getState().claims.filter((claim) => claim.wallet === wallet)
  }

  async readRecentActivity(wallet: string, limit = 25) {
    return this.getState()
      .events.filter((event) => event.wallet === wallet)
      .slice(-limit)
      .reverse()
  }

  async readSnapshot(wallet: string) {
    const [summary, progress, claims, recentActivity, referralProfile] = await Promise.all([
      this.readRewardSummary(wallet),
      this.readProgress(wallet),
      this.readClaimHistory(wallet),
      this.readRecentActivity(wallet),
      this.readReferralProfile(wallet),
    ])

    return {
      wallet,
      summary,
      progress,
      claims,
      recentActivity,
      referralProfile,
    }
  }
}
