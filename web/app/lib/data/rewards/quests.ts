import { imageForTask, type RewardsPromoTabId, type RewardsQuest } from "./catalog"

// Placeholder quests of the Rewards screens. No rewards program or points ledger exists yet,
// so nothing is tracked or granted: every quest renders as "Coming soon".

type PlaceholderQuest = Omit<RewardsQuest, "image" | "status" | "progressLabel" | "cta">

const QUESTS: Record<RewardsPromoTabId, PlaceholderQuest[]> = {
  "getting-started": [
    {
      id: "connect-wallet",
      title: "Connect your wallet",
      description: "Connect a wallet to start using Avana.",
      reward: "25 AVA",
      category: "Setup",
      iconId: "wallet",
    },
    {
      id: "review-risk-basics",
      title: "Read the LP risk primer",
      description: "Learn how LP collateral, health factor and liquidation work.",
      reward: "15 AVA",
      category: "Education",
      iconId: "shieldCheck",
    },
    {
      id: "favorite-market",
      title: "Pin a market to watch",
      description: "Pin a Lend or Borrow market to follow its rates.",
      reward: "20 AVA",
      category: "Setup",
      iconId: "target",
    },
  ],
  lend: [
    {
      id: "first-lend-deposit",
      title: "Make your first deposit",
      description: "Supply an asset to any Lend market.",
      reward: "40 AVA",
      category: "Lend",
      iconId: "droplets",
    },
    {
      id: "supply-500-lend",
      title: "Supply $500",
      description: "Reach $500 supplied across Lend markets.",
      reward: "100 AVA",
      category: "Lend",
      iconId: "droplets",
    },
    {
      id: "favorite-lend-market",
      title: "Pin a Lend market to watch",
      description: "Follow a Lend market's supply rate.",
      reward: "20 AVA",
      category: "Lend",
      iconId: "target",
    },
  ],
  borrow: [
    {
      id: "first-borrow",
      title: "Open your first loan",
      description: "Borrow against an LP position you pledged.",
      reward: "50 AVA",
      category: "Borrow",
      iconId: "rocket",
    },
    {
      id: "first-repay",
      title: "Repay a loan",
      description: "Repay part or all of a loan.",
      reward: "30 AVA",
      category: "Borrow",
      iconId: "repeat2",
    },
    {
      id: "pledge-uniswap-v3-position",
      title: "Pledge a Uniswap v3 position",
      description: "Use a Uniswap v3 LP position as collateral.",
      reward: "60 AVA",
      category: "Borrow",
      iconId: "orbit",
    },
  ],
  referrals: [
    {
      id: "share-referral-link",
      title: "Copy your invite link",
      description: "Share Avana with a friend.",
      reward: "15 AVA",
      category: "Referral",
      iconId: "link2",
    },
    {
      id: "invite-first-wallet",
      title: "Send your first invite",
      description: "Invite a friend who connects a wallet.",
      reward: "40 AVA",
      category: "Referral",
      iconId: "link2",
    },
    {
      id: "bring-3-active-users",
      title: "Invite 3 active friends",
      description: "Three invited friends open a position.",
      reward: "150 AVA",
      category: "Referral",
      iconId: "trophy",
    },
  ],
}

/** The placeholder quests of each Rewards tab, ready for the quest cards. */
export function placeholderQuestsByTab(comingSoonLabel: string): Record<RewardsPromoTabId, RewardsQuest[]> {
  const entries = Object.entries(QUESTS).map(([tab, quests]) => [
    tab,
    quests.map((quest) => ({
      ...quest,
      image: imageForTask(quest.id),
      cta: comingSoonLabel,
      status: "coming_soon" as const,
      progressLabel: quest.description,
    })),
  ])
  return Object.fromEntries(entries) as Record<RewardsPromoTabId, RewardsQuest[]>
}
