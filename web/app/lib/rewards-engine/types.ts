export type RewardTaskCategory = "new_user" | "challenge" | "referral"

export type RewardTaskStatus = "locked" | "available" | "in_progress" | "claimable" | "claimed" | "expired"

export type RewardTaskTag =
  | "setup"
  | "education"
  | "simulation"
  | "lend"
  | "borrow"
  | "multiply"
  | "risk"
  | "rewards"
  | "referral"
  | "volume"
  | "streak"
  | "integration"
  | "mastery"
  | "product"
  | "activity"

export type RewardProduct = "profile" | "borrow" | "multiply" | "lend" | "rewards" | "referral" | "education"

export type RewardActivityType =
  | "wallet_connected"
  | "profile_completed"
  | "market_favorited"
  | "simulation_created"
  | "lend_deposited"
  | "lend_withdrawn"
  | "borrow_opened"
  | "borrow_repaid"
  | "borrow_position_healthy"
  | "curve_lp_used"
  | "uniswap_v4_lp_used"
  | "multiply_opened"
  | "multiply_deleveraged"
  | "multiply_safe_period_completed"
  | "reward_claimed"
  | "referral_link_created"
  | "referral_connected"
  | "referral_activated"
  | "referral_funded"
  | "education_completed"
  | "sandbox_tour_completed"
  | "daily_checkin"

export type RewardTaskRequirement =
  | {
      type: "event_count"
      eventTypes: RewardActivityType[]
      targetCount: number
      product?: RewardProduct
      minAmountUsd?: number
      distinctProducts?: RewardProduct[]
      distinctMarketIds?: boolean
      marketId?: string
    }
  | {
      type: "aggregate_volume"
      eventTypes: RewardActivityType[]
      targetUsd: number
    }
  | {
      type: "holding_period"
      eventTypes: RewardActivityType[]
      targetCount: number
      durationDays: number
      minAmountUsd?: number
    }
  | {
      type: "streak"
      eventTypes: RewardActivityType[]
      targetCount: number
      interval: "day" | "week"
    }
  | {
      type: "referral_count"
      eventTypes: RewardActivityType[]
      targetCount: number
    }
  | {
      type: "education_completed"
      targetCount: number
    }
  | {
      type: "profile_completed"
      targetCount: number
    }
  | {
      type: "wait_since_login"
      waitMs: number
    }

export type RewardTask = {
  id: string
  category: RewardTaskCategory
  tag: RewardTaskTag
  title: string
  description: string
  rewardAmount: number
  rewardSymbol: "AVA"
  actionLabel: string
  requirement: RewardTaskRequirement
  expiresAt?: number
  repeatable: boolean
  status?: RewardTaskStatus
  actionKind?: RewardTaskActionKind
}

export type RewardTaskActionKind =
  | "auto"
  | "education_modal"
  | "favorite_modal"
  | "simulate_modal"
  | "deep_link"
  | "copy_referral"
  | "sandbox_referral_invite"
  | "sandbox_referral_activate"
  | "sandbox_referral_fund"
  | "sandbox_tour"
  | "wait_timer"
  | "product_action"

export type UserRewardProgress = {
  wallet: string
  taskId: string
  status: RewardTaskStatus
  progress: number
  target: number
  claimableAmount: number
  claimedAmount: number
  startedAt?: number
  completedAt?: number
  claimedAt?: number
}

export type RewardClaim = {
  claimId: string
  wallet: string
  taskId: string
  amount: number
  rewardSymbol: "AVA"
  status: "pending" | "confirmed"
  syntheticTxHash: string
  claimedAt: number
}

export type RewardActivityEvent = {
  id: string
  wallet: string
  product: RewardProduct
  type: RewardActivityType
  amountUsd?: number
  marketId?: string
  referredWallet?: string
  timestamp: number
}

export type ReferralProfile = {
  wallet: string
  referralCode: string
  referralLink: string
  referredBy?: string
  activeReferralCount: number
  fundedReferralCount: number
  referralVolumeUsd: number
  createdAt: number
}

export type ReferralRelationship = {
  referrerWallet: string
  referredWallet: string
  createdAt: number
  activatedAt?: number
  fundedAt?: number
  fundedVolumeUsd?: number
}

export type RewardsSummary = {
  wallet: string
  completedTaskCount: number
  claimableTaskCount: number
  totalTaskCount: number
  totalEarnedAmount: number
  totalClaimableAmount: number
  totalClaimedAmount: number
}

export type RewardsEngineState = {
  events: RewardActivityEvent[]
  claims: RewardClaim[]
}
