import { imageForTask, type RewardsPromoTabId, type RewardsQuest } from "./catalog"

// Quests of the Rewards screens. Points are granted by Convex (services/convex lib/rewards.ts, `QUEST_POINTS`) for
// the four quests with a source; the rest are "Coming soon".

type PlaceholderQuest = Omit<RewardsQuest, "image" | "status" | "progressLabel" | "cta">

const QUESTS: Record<RewardsPromoTabId, PlaceholderQuest[]> = {
  "getting-started": [
    {
      id: "connect-wallet",
      title: "Connect your wallet",
      description: "Connect a wallet to start using Avana.",
      reward: "25 pts",
      category: "Setup",
      iconId: "wallet",
    },
    {
      id: "review-risk-basics",
      title: "Read the LP risk primer",
      description: "Learn how LP collateral, health factor and liquidation work.",
      reward: "15 pts",
      category: "Education",
      iconId: "shieldCheck",
    },
    {
      id: "favorite-market",
      title: "Pin a market to watch",
      description: "Pin a Lend or Borrow market to follow its rates.",
      reward: "20 pts",
      category: "Setup",
      iconId: "target",
    },
  ],
  lend: [
    {
      id: "first-lend-deposit",
      title: "Make your first deposit",
      description: "Supply an asset to any Lend market.",
      reward: "40 pts",
      category: "Lend",
      iconId: "droplets",
    },
    {
      id: "supply-500-lend",
      title: "Supply $500",
      description: "Reach $500 supplied across Lend markets.",
      reward: "100 pts",
      category: "Lend",
      iconId: "droplets",
    },
    {
      id: "favorite-lend-market",
      title: "Pin a Lend market to watch",
      description: "Follow a Lend market's supply rate.",
      reward: "20 pts",
      category: "Lend",
      iconId: "target",
    },
  ],
  borrow: [
    {
      id: "first-borrow",
      title: "Open your first loan",
      description: "Borrow against an LP position you pledged.",
      reward: "50 pts",
      category: "Borrow",
      iconId: "rocket",
    },
    {
      id: "first-repay",
      title: "Repay a loan",
      description: "Repay part or all of a loan.",
      reward: "30 pts",
      category: "Borrow",
      iconId: "repeat2",
    },
    {
      id: "pledge-uniswap-v3-position",
      title: "Pledge a Uniswap v3 position",
      description: "Use a Uniswap v3 LP position as collateral.",
      reward: "60 pts",
      category: "Borrow",
      iconId: "orbit",
    },
  ],
  referrals: [
    {
      id: "share-referral-link",
      title: "Copy your invite link",
      description: "Share Avana with a friend.",
      reward: "15 pts",
      category: "Referral",
      iconId: "link2",
    },
    {
      id: "invite-first-wallet",
      title: "Send your first invite",
      description: "Invite a friend who connects a wallet.",
      reward: "40 pts",
      category: "Referral",
      iconId: "link2",
    },
    {
      id: "bring-3-active-users",
      title: "Invite 3 active friends",
      description: "Three invited friends open a position.",
      reward: "150 pts",
      category: "Referral",
      iconId: "trophy",
    },
  ],
}

/** Where each quest's card takes the wallet, and the label of that button. */
const QUEST_ACTIONS: Record<string, { href: string; cta: string }> = {
  "connect-wallet": { href: "/dashboard", cta: "Connect Wallet" },
  "first-lend-deposit": { href: "/lend", cta: "Deposit" },
  "supply-500-lend": { href: "/lend", cta: "Deposit" },
  "first-borrow": { href: "/borrow", cta: "Borrow" },
  "first-repay": { href: "/borrow", cta: "Repay" },
  "pledge-uniswap-v3-position": { href: "/borrow", cta: "Pledge" },
}

/** The page a real quest's button opens; undefined for a quest that is not live yet. */
export function questHref(questId: string): string | undefined {
  return QUEST_ACTIONS[questId]?.href
}

/**
 * The quests of each Rewards tab, ready for the quest cards. The five with a source (first deposit, borrow, repay,
 * pledge and $500 supplied, detected from the wallet's own on-chain activity) show "Earned" once completed and
 * otherwise open the page where they are done; every other quest is "Coming soon".
 */
export function questsByTab(
  labels: { comingSoon: string; earned: string },
  completed: ReadonlySet<string>,
): Record<RewardsPromoTabId, RewardsQuest[]> {
  const entries = Object.entries(QUESTS).map(([tab, quests]) => [
    tab,
    quests.map((quest) => {
      const base = { ...quest, image: imageForTask(quest.id), progressLabel: quest.description }
      const action = QUEST_ACTIONS[quest.id]
      if (!action) return { ...base, cta: labels.comingSoon, status: "coming_soon" as const }
      return completed.has(quest.id)
        ? { ...base, cta: labels.earned, status: "claimed" as const }
        : { ...base, cta: action.cta, status: "available" as const }
    }),
  ])
  return Object.fromEntries(entries) as Record<RewardsPromoTabId, RewardsQuest[]>
}
