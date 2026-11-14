import type {
  ReferralProfile,
  ReferralRelationship,
  RewardActivityEvent,
  RewardClaim,
  RewardsSummary,
  RewardTask,
  UserRewardProgress,
} from "@/app/lib/rewards-engine"

export type RewardsSessionState = {
  events: RewardActivityEvent[]
  claims: RewardClaim[]
  referralProfiles: Record<string, ReferralProfile>
  relationships: ReferralRelationship[]
  firstLoginAt: number
  favoriteMarketIds: string[]
}

export type RewardsReadSnapshot = {
  wallet: string
  summary: RewardsSummary
  progress: UserRewardProgress[]
  claims: RewardClaim[]
  recentActivity: RewardActivityEvent[]
  referralProfile: ReferralProfile | null
}

export type RewardsReadAdapter = {
  mode: "sandbox" | "production"
  readTasks(): Promise<RewardTask[]>
  readProgress(wallet: string): Promise<UserRewardProgress[]>
  readRewardSummary(wallet: string): Promise<RewardsSummary>
  readReferralProfile(wallet: string): Promise<ReferralProfile | null>
  readClaimHistory(wallet: string): Promise<RewardClaim[]>
  readRecentActivity(wallet: string, limit?: number): Promise<RewardActivityEvent[]>
  readSnapshot(wallet: string): Promise<RewardsReadSnapshot>
}

export type RewardsActionAdapter = {
  mode: "sandbox" | "production"
  initializeRewardsForWallet(wallet: string): Promise<RewardsSessionState>
  recordActivityEvent(event: RewardActivityEvent): Promise<RewardsSessionState>
  completeSandboxTask(wallet: string, taskId: string): Promise<RewardsSessionState>
  completeEducation(wallet: string): Promise<RewardsSessionState>
  favoriteMarket(wallet: string, marketId: string): Promise<RewardsSessionState>
  recordSimulation(wallet: string, product: "borrow" | "lend" | "multiply"): Promise<RewardsSessionState>
  recordSandboxTour(wallet: string, taskId: string): Promise<RewardsSessionState>
  recordDailyCheckin(wallet: string): Promise<RewardsSessionState>
  runReferralSandboxStep(wallet: string, step: "invite" | "activate" | "fund"): Promise<RewardsSessionState>
  refreshTaskProgress(wallet: string): Promise<UserRewardProgress[]>
  claimReward(wallet: string, taskId: string): Promise<RewardClaim>
  claimAllRewards(wallet: string): Promise<RewardClaim[]>
  createReferralCode(wallet: string): Promise<ReferralProfile>
  recordReferralLinkCopied(wallet: string): Promise<RewardsSessionState>
  applyReferralCode(wallet: string, referralCode: string): Promise<ReferralRelationship>
}
