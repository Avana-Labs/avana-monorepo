import type { RewardActivityEvent } from "@/app/lib/rewards-engine"

const DAY_MS = 24 * 60 * 60 * 1000

export function makeStressRewardEvents(walletCount: number, startAt = Date.UTC(2026, 5, 1)) {
  const events: RewardActivityEvent[] = []

  for (let index = 0; index < walletCount; index += 1) {
    const wallet = `wallet-rewards-stress-${index}`
    const base = startAt + index * 60_000

    events.push(
      { id: `${wallet}:connect`, wallet, product: "profile", type: "wallet_connected", timestamp: base },
      { id: `${wallet}:profile`, wallet, product: "profile", type: "profile_completed", timestamp: base + 1 },
      { id: `${wallet}:risk`, wallet, product: "education", type: "education_completed", timestamp: base + 2 },
      {
        id: `${wallet}:favorite`,
        wallet,
        product: "profile",
        type: "market_favorited",
        marketId: `market-${index % 12}`,
        timestamp: base + 3,
      },
      { id: `${wallet}:simulate`, wallet, product: "borrow", type: "simulation_created", timestamp: base + 4 },
    )

    if (index % 2 === 0) {
      events.push(
        {
          id: `${wallet}:lend`,
          wallet,
          product: "lend",
          type: "lend_deposited",
          amountUsd: 6_000 + index,
          marketId: `lend-${index % 20}`,
          timestamp: base + 10,
        },
        {
          id: `${wallet}:borrow`,
          wallet,
          product: "borrow",
          type: "borrow_opened",
          amountUsd: 2_500 + index,
          marketId: `borrow-${index % 20}`,
          timestamp: base + 11,
        },
        {
          id: `${wallet}:repay`,
          wallet,
          product: "borrow",
          type: "borrow_repaid",
          amountUsd: 600 + index,
          marketId: `borrow-${index % 20}`,
          timestamp: base + 12,
        },
        {
          id: `${wallet}:multiply`,
          wallet,
          product: "multiply",
          type: "multiply_opened",
          amountUsd: 3_000 + index,
          marketId: `multiply-${index % 20}`,
          timestamp: base + 13,
        },
        {
          id: `${wallet}:deleverage`,
          wallet,
          product: "multiply",
          type: "multiply_deleveraged",
          amountUsd: 1_200 + index,
          marketId: `multiply-${index % 20}`,
          timestamp: base + 14,
        },
        { id: `${wallet}:curve`, wallet, product: "borrow", type: "curve_lp_used", timestamp: base + 15 },
        { id: `${wallet}:uni`, wallet, product: "borrow", type: "uniswap_v4_lp_used", timestamp: base + 16 },
      )
    }

    if (index % 4 === 0) {
      events.push(
        {
          id: `${wallet}:borrow-healthy-start`,
          wallet,
          product: "borrow",
          type: "borrow_position_healthy",
          timestamp: base + 20,
        },
        {
          id: `${wallet}:borrow-healthy-end`,
          wallet,
          product: "borrow",
          type: "borrow_position_healthy",
          timestamp: base + 20 + 14 * DAY_MS,
        },
        {
          id: `${wallet}:multiply-safe-start`,
          wallet,
          product: "multiply",
          type: "multiply_safe_period_completed",
          timestamp: base + 21,
        },
        {
          id: `${wallet}:multiply-safe-end`,
          wallet,
          product: "multiply",
          type: "multiply_safe_period_completed",
          timestamp: base + 21 + 14 * DAY_MS,
        },
      )
    }

    if (index % 5 === 0) {
      for (let week = 0; week < 4; week += 1) {
        events.push({
          id: `${wallet}:weekly-${week}`,
          wallet,
          product: "lend",
          type: "lend_deposited",
          amountUsd: 100 + week,
          timestamp: base + week * 7 * DAY_MS,
        })
      }
    }

    if (index % 10 === 0) {
      for (let referral = 0; referral < 5; referral += 1) {
        const referredWallet = `${wallet}:referred:${referral}`
        events.push(
          {
            id: `${wallet}:ref-link`,
            wallet,
            product: "referral",
            type: "referral_link_created",
            timestamp: base + 30,
          },
          {
            id: `${wallet}:ref-connect:${referral}`,
            wallet,
            product: "referral",
            type: "referral_connected",
            referredWallet,
            timestamp: base + 31 + referral,
          },
          {
            id: `${wallet}:ref-activated:${referral}`,
            wallet,
            product: "referral",
            type: "referral_activated",
            referredWallet,
            timestamp: base + 32 + referral,
          },
          {
            id: `${wallet}:ref-funded:${referral}`,
            wallet,
            product: "referral",
            type: "referral_funded",
            referredWallet,
            amountUsd: 6_000,
            timestamp: base + 33 + referral,
          },
        )
      }
    }
  }

  return events
}
