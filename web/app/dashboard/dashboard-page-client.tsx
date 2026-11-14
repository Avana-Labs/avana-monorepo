"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import {
  emptyRewardsQuestsByTab,
  imageForTask,
  resolveRewardsPromoTab,
  type RewardsPromoTabId,
  type RewardsQuest,
  type RewardsQuestIconId,
} from "@/app/lib/data/rewards/catalog"
import type { RewardsPageData } from "@/app/lib/data/providers/rewards"
import { useAvanaSessions, useRewardsSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { getWalletBalanceForLendMarket } from "@/app/lib/lend-system/wallet-balances"
import type { RewardTask, UserRewardProgress } from "@/app/lib/rewards-engine"
import { calculateRewardSummary, evaluateAllTasksForUser } from "@/app/lib/rewards-engine"
import {
  canRunTaskAction,
  findTaskById,
  getSandboxTour,
  getTaskActionKind,
  getTaskDeepLink,
  isReferralTaskAction,
} from "@/app/lib/rewards-engine/task-actions"
import { DashboardLoading } from "@/app/components/loading-states"
import { buildRewardsActivityHistory } from "@/app/lib/rewards-system"
import { useDurableRewardsClaim } from "@/app/lib/rewards-system"
import { PortfolioStatCards } from "@/app/dashboard/portfolio-stat-cards"
import { PortfolioRewardsCards } from "@/app/dashboard/_rewards-components/rewards-balance-hero"
import { DashboardWalletTab } from "./dashboard-wallet-tab"
import { LearnSection } from "@/app/dashboard/_rewards-components/learn-section"
import { RecentActivity } from "@/app/dashboard/recent-activity"
import {
  mapConvexSwapTransactionsToActivityRows,
  mapSwapTransactionHistoryToActivityRows,
} from "@/app/dashboard/swap-activity"
import { mapTransactionHistoryToActivityRows } from "@/app/lib/borrow-system/read-model"
import { buildLendActivityHistory } from "@/app/lib/lend-system/read-model"
import { ActionIcon } from "@/app/components/action-icon"
import { detailSectionStackClass, MobileDetailActionBar } from "@/app/components/detail-page-primitives"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import {
  RewardsEducationDialog,
  RewardsFavoriteDialog,
  RewardsReferralDialog,
  RewardsSimulateDialog,
} from "@/app/dashboard/_rewards-components/rewards-task-dialogs"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { UnderlineTabStrip } from "@/app/components/tab-primitives"
import { RewardsPromoContent, RewardsQuestSection } from "@/app/dashboard/_rewards-components/quests-tab"
import { MerklRewardsSection } from "@/app/dashboard/_rewards-components/merkl-rewards-section"
import Link from "next/link"

type DashboardPromoTabId = Extract<RewardsPromoTabId, "getting-started" | "lend" | "borrow" | "referrals">
type DashboardAccountTabId = Extract<RewardsPromoTabId, "lend" | "borrow">
type DashboardTabId = "wallet" | DashboardAccountTabId | "rewards"

const DASHBOARD_TABS: readonly { id: DashboardTabId; label: string }[] = [
  { id: "wallet", label: "Wallet" },
  { id: "lend", label: "Lend" },
  { id: "borrow", label: "Borrow" },
  { id: "rewards", label: "Rewards" },
]

const CURATED_REWARD_TASK_IDS: Record<DashboardPromoTabId, readonly string[]> = {
  "getting-started": ["connect-wallet", "review-risk-basics", "run-first-simulation"],
  lend: ["first-lend-deposit", "favorite-market", "supply-5k-lend"],
  borrow: ["first-borrow", "first-repay", "use-curve-position"],
  referrals: ["share-referral-link", "invite-first-wallet", "bring-3-active-users"],
}

function resolveDashboardTab(tab: string | null): DashboardTabId {
  switch (tab) {
    case "wallet":
    case "lend":
    case "borrow":
    case "rewards":
      return tab
    case "referrals":
      return "rewards"
    // Former All Transactions tab / activity aliases → default wallet tab.
    // Activity now lives in the sidebar feed.
    case "transactions":
    case "activity":
    default:
      return "wallet"
  }
}

function curateDashboardQuests(
  tab: DashboardPromoTabId,
  quests: RewardCardViewModel[],
  maxCount: number,
): RewardCardViewModel[] {
  const preferredIds = CURATED_REWARD_TASK_IDS[tab]
  if (preferredIds.length === 0) return quests.slice(0, maxCount)

  const byId = new Map(quests.map((quest) => [quest.id, quest]))
  const curated = preferredIds.map((id) => byId.get(id)).filter((quest): quest is RewardCardViewModel => Boolean(quest))
  const remainder = quests.filter((quest) => !preferredIds.includes(quest.id))
  return [...curated, ...remainder].slice(0, maxCount)
}

type RewardsSnapshot = {
  summary: {
    completedTaskCount: number
    claimableTaskCount: number
    totalTaskCount: number
    totalEarnedAmount: number
    totalClaimableAmount: number
    totalClaimedAmount: number
  }
  progress: UserRewardProgress[]
}

type RewardCardViewModel = RewardsQuest & {
  status: UserRewardProgress["status"]
  progressLabel: string
}

function titleCase(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}

function tagToIconId(tag: RewardTask["tag"]): RewardsQuestIconId {
  switch (tag) {
    case "lend":
      return "droplets"
    case "borrow":
      return "rocket"
    case "multiply":
      return "layers3"
    case "referral":
      return "link2"
    case "risk":
      return "shieldCheck"
    case "rewards":
      return "sparkles"
    case "streak":
      return "flame"
    case "integration":
      return "orbit"
    case "mastery":
      return "trophy"
    case "education":
      return "shieldCheck"
    case "simulation":
      return "target"
    default:
      return "wallet"
  }
}

function formatDuration(ms: number) {
  const totalSeconds = Math.ceil(ms / 1000)
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  if (minutes > 0) return `${minutes}m ${seconds}s`
  return `${seconds}s`
}

function isReferralClaimCta(task: RewardTask, t: (key: string) => string) {
  const actionKind = getTaskActionKind(task)
  if (actionKind === "copy_referral") return t("View link & claim")
  if (actionKind === "sandbox_referral_invite") return t("View invite & claim")
  if (isReferralTaskAction(actionKind)) return t("View crew & claim")
  return t("Claim {amount} AVA").replace("{amount}", String(task.rewardAmount))
}

function buildProgressLabel(
  task: RewardTask,
  progress: UserRewardProgress,
  firstLoginAt: number,
  now: number,
  t: (key: string) => string,
  exact: (usd: number) => string,
) {
  if (progress.status === "claimed") return t("Claimed")
  if (progress.status === "claimable") return t("Ready to claim")
  if (progress.status === "expired") return t("Expired")

  if (task.requirement.type === "wait_since_login" && firstLoginAt > 0) {
    const remaining = task.requirement.waitMs - (now - firstLoginAt)
    if (remaining > 0) return t("Unlocks in {duration}").replace("{duration}", formatDuration(remaining))
  }

  if (task.requirement.type === "aggregate_volume") {
    return t("{progress}/{target} {currency}")
      .replace("{progress}", exact(Math.round(progress.progress)))
      .replace("{target}", exact(progress.target))
      .replace("{currency}", "")
      .trim()
  }

  return t("{progress}/{target} complete")
    .replace("{progress}", String(Math.min(Math.round(progress.progress), progress.target)))
    .replace("{target}", String(progress.target))
}

function buildRewardsSnapshot(
  walletId: string,
  tasks: RewardTask[],
  state: {
    events: Parameters<typeof evaluateAllTasksForUser>[0]["events"]
    claims: Parameters<typeof evaluateAllTasksForUser>[0]["claims"]
    firstLoginAt: number
  },
  now: number,
): RewardsSnapshot {
  const progress = evaluateAllTasksForUser({
    tasks,
    wallet: walletId,
    events: state.events,
    claims: state.claims,
    now,
    firstLoginAt: state.firstLoginAt,
  })
  const summary = calculateRewardSummary({
    tasks,
    wallet: walletId,
    events: state.events,
    claims: state.claims,
    now,
    firstLoginAt: state.firstLoginAt,
  })

  return { summary, progress }
}

function DashboardRewardsTab({
  questsByTab,
  onTaskAction,
}: {
  questsByTab: Record<RewardsPromoTabId, RewardCardViewModel[]>
  onTaskAction: (taskId: string) => Promise<unknown>
}) {
  const sections: Array<{ id: DashboardPromoTabId; title: string }> = [
    { id: "getting-started", title: "Getting Started" },
    { id: "lend", title: "Lend Rewards" },
    { id: "borrow", title: "Borrow Rewards" },
    { id: "referrals", title: "Referral Rewards" },
  ]

  return (
    <div className={detailSectionStackClass}>
      {sections.map(({ id, title }) => {
        const quests = questsByTab[id] ?? []
        if (quests.length === 0) return null
        return <RewardsQuestSection key={id} title={title} quests={quests} onTaskAction={onTaskAction} />
      })}
      <MerklRewardsSection />
    </div>
  )
}

function mapTaskToQuest(
  task: RewardTask,
  progress: UserRewardProgress,
  firstLoginAt: number,
  now: number,
  t: (key: string) => string,
  exact: (usd: number) => string,
): RewardCardViewModel {
  return {
    id: task.id,
    title: task.title,
    description: task.description,
    reward: `${task.rewardAmount} ${task.rewardSymbol}`,
    cta:
      progress.status === "claimable"
        ? isReferralClaimCta(task, t)
        : progress.status === "claimed"
          ? t("Claimed")
          : task.actionKind === "wait_timer"
            ? t("Waiting")
            : task.actionLabel,
    category: titleCase(task.tag),
    iconId: tagToIconId(task.tag),
    image: imageForTask(task.id),
    status: progress.status,
    progressLabel: buildProgressLabel(task, progress, firstLoginAt, now, t, exact),
  }
}

export function DashboardPageClient({ pageData: _pageData }: { pageData?: RewardsPageData }) {
  const router = useRouter()
  const searchParams = useSearchParams()
  const searchTab = searchParams.get("tab")
  const referralRef = searchParams.get("ref")
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const avana = useAvanaSessions()
  const {
    walletId,
    state,
    hasHydratedStorage,
    tasks,
    completeEducation,
    favoriteMarket,
    recordSimulation,
    recordSandboxTour,
    recordDailyCheckin,
    runReferralSandboxStep,
    createReferralCode,
    recordReferralLinkCopied,
    applyReferralCode,
  } = useRewardsSessionContext()
  const persistRewardsClaim = useDurableRewardsClaim()
  const [now, setNow] = useState(0)
  const [isClaiming, setIsClaiming] = useState(false)
  const [educationOpen, setEducationOpen] = useState(false)
  const [favoriteOpen, setFavoriteOpen] = useState(false)
  const [simulateOpen, setSimulateOpen] = useState(false)
  const [referralOpen, setReferralOpen] = useState(false)
  const [referralTaskId, setReferralTaskId] = useState<string | null>(null)
  const [referralLink, setReferralLink] = useState("")
  const [referralCode, setReferralCode] = useState("")
  const [activeDashboardTab, setActiveDashboardTab] = useState<DashboardTabId>(() => resolveDashboardTab(searchTab))

  useEffect(() => {
    setActiveDashboardTab(resolveDashboardTab(searchTab))
  }, [searchTab])

  useEffect(() => {
    if (!hasHydratedStorage || !referralRef) return
    void applyReferralCode(referralRef).catch(() => undefined)
  }, [applyReferralCode, hasHydratedStorage, referralRef])

  const snapshot = useMemo(() => {
    if (!hasHydratedStorage) return null
    return buildRewardsSnapshot(walletId, tasks, state, now > 0 ? now : Date.now())
  }, [hasHydratedStorage, now, state.claims, state.events, state.firstLoginAt, tasks, walletId])

  const reloadSnapshot = useCallback(() => {
    setNow(Date.now())
  }, [])

  useEffect(() => {
    if (!hasHydratedStorage) return
    reloadSnapshot()
  }, [hasHydratedStorage, reloadSnapshot, state.events.length, state.claims.length, state.firstLoginAt])

  const hasPendingWaitTask = useMemo(
    () =>
      snapshot?.progress.some((entry) => {
        const task = tasks.find((item) => item.id === entry.taskId)
        return task?.actionKind === "wait_timer" && entry.status === "in_progress"
      }) ?? false,
    [snapshot?.progress, tasks],
  )

  useEffect(() => {
    if (!hasPendingWaitTask) return undefined
    const tickIfVisible = () => {
      if (document.visibilityState === "visible") reloadSnapshot()
    }
    const timer = window.setInterval(tickIfVisible, 5_000)
    document.addEventListener("visibilitychange", tickIfVisible)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener("visibilitychange", tickIfVisible)
    }
  }, [hasPendingWaitTask, reloadSnapshot])

  const questsByTab = useMemo(() => {
    if (!snapshot) return emptyRewardsQuestsByTab<RewardCardViewModel>()

    const progressByTaskId = new Map(snapshot.progress.map((item) => [item.taskId, item]))
    const grouped = tasks.reduce<Record<RewardsPromoTabId, RewardCardViewModel[]>>((accumulator, task) => {
      const progress = progressByTaskId.get(task.id)
      if (!progress) return accumulator
      accumulator[resolveRewardsPromoTab(task)].push(mapTaskToQuest(task, progress, state.firstLoginAt, now, t, exact))
      return accumulator
    }, emptyRewardsQuestsByTab<RewardCardViewModel>())

    // Each group holds exactly three curated quests; keep the intended order.
    for (const key of Object.keys(grouped) as RewardsPromoTabId[]) {
      grouped[key] = curateDashboardQuests(key, grouped[key], 3)
    }
    return grouped
  }, [tasks, snapshot, state.firstLoginAt, now, t, exact])

  const runReferralActivations = useCallback(async () => {
    await runReferralSandboxStep("activate")
  }, [runReferralSandboxStep])

  const referralTask = referralTaskId ? (tasks.find((task) => task.id === referralTaskId) ?? null) : null
  const referralProgress = snapshot?.progress.find((item) => item.taskId === referralTaskId) ?? null

  const openReferralDialog = useCallback((taskId: string) => {
    setReferralTaskId(taskId)
    setReferralOpen(true)
  }, [])

  const handleSimulate = useCallback(
    async (product: "borrow" | "lend") => {
      if (product === "lend") {
        const marketId = "gho"
        const intent = avana.lend.createIntent({
          type: "deposit",
          walletId,
          marketId,
          depositAmount: 100,
          walletBalance: getWalletBalanceForLendMarket(avana.lend.state, walletId, { marketId }),
        })
        await avana.lend.previewTransaction(intent)
      } else {
        const pool = avana.borrow.collateralPools[0]
        const asset = pool ? avana.borrow.getBorrowableAssetsForMarket(pool.id)[0] : undefined
        if (!pool || !asset) throw new Error("Borrow sandbox is not ready")
        const intent = avana.borrow.createIntent({
          type: "borrow",
          walletId,
          marketId: pool.id,
          assetId: asset.id,
          amountUsd6: 100_000_000n,
          at: Date.now(),
        })
        await avana.borrow.previewTransaction(intent)
      }
      await recordSimulation(product)
      reloadSnapshot()
    },
    [avana.borrow, avana.lend, recordSimulation, reloadSnapshot, walletId],
  )

  const handleTaskAction = useCallback(
    async (taskId: string) => {
      const task = findTaskById(taskId)
      const progress = snapshot?.progress.find((item) => item.taskId === taskId)
      if (!task || !progress) return

      const actionKind = getTaskActionKind(task)

      if (isReferralTaskAction(actionKind)) {
        openReferralDialog(taskId)
        return
      }

      if (progress.status === "claimable") {
        if (isClaiming) return
        setIsClaiming(true)
        try {
          await persistRewardsClaim([taskId])
          reloadSnapshot()
        } finally {
          setIsClaiming(false)
        }
        return
      }

      if (!canRunTaskAction(progress, actionKind)) return

      switch (actionKind) {
        case "education_modal":
          setEducationOpen(true)
          return
        case "favorite_modal":
          setFavoriteOpen(true)
          return
        case "simulate_modal":
          setSimulateOpen(true)
          return
        case "deep_link": {
          const href = getTaskDeepLink(taskId)
          if (href) router.push(href)
          return
        }
        case "sandbox_tour": {
          await recordSandboxTour(taskId)
          const tour = getSandboxTour(taskId)
          if (tour?.href) router.push(tour.href)
          reloadSnapshot()
          return
        }
        case "product_action":
          if (taskId === "4-week-activity-streak") {
            await recordDailyCheckin()
            reloadSnapshot()
            return
          }
          if (getTaskDeepLink(taskId)) {
            router.push(getTaskDeepLink(taskId)!)
          }
          return
        default:
          return
      }
    },
    [
      persistRewardsClaim,
      isClaiming,
      openReferralDialog,
      recordDailyCheckin,
      recordSandboxTour,
      reloadSnapshot,
      router,
      snapshot?.progress,
    ],
  )

  const handleDashboardTabChange = useCallback(
    (tab: DashboardTabId) => {
      setActiveDashboardTab(tab)
      // Keep scroll position when swapping portfolio tabs — default App Router
      // navigation resets to the top of the page.
      router.push(`/dashboard?tab=${tab}`, { scroll: false })
    },
    [router],
  )

  if (!hasHydratedStorage || !snapshot) {
    // Bare loading state — the dashboard route already provides the page wrapper, so
    // wrapping again would shift it below/narrower than the real content. Announces the
    // load to assistive tech and offers a retry if the snapshot is slow to arrive.
    return <DashboardLoading onRetry={reloadSnapshot} />
  }

  const claimHref = snapshot.summary.claimableTaskCount > 0 ? "/actions/rewards/claim" : undefined
  const rewardActivityRows = buildRewardsActivityHistory(walletId, state.claims, tasks)
  // Swap activity: the in-session rows (live) plus any durable Convex-persisted swaps not
  // already in-session, so a swap survives reload / shows cross-device. Deduped by swap id
  // (the two sources carry different tx hashes, so the hash-dedup below can't unify them). (#15)
  const sessionSwapRows = mapSwapTransactionHistoryToActivityRows(avana.swap.transactionHistory)
  const sessionSwapIds = new Set(sessionSwapRows.map((row) => row.id))
  const swapActivityRows = [
    ...sessionSwapRows,
    ...mapConvexSwapTransactionsToActivityRows(avana.swap.durableTransactions ?? []).filter(
      (row) => !sessionSwapIds.has(row.id),
    ),
  ]
  // One combined "recent activity" table: live session actions + reward claims, merged by
  // RecentActivity with its paginated Convex getActivity feed (all products). RecentActivity deduplicates by id and by the
  // composite hash/action/market identity, so distinct same-hash actions remain visible.
  const combinedActivityRows = [
    ...mapTransactionHistoryToActivityRows(avana.borrow.transactionHistory, avana.borrow.state.markets),
    ...buildLendActivityHistory(avana.lend.walletId, avana.lend.transactionHistory, avana.lend.state),
    ...swapActivityRows,
    ...rewardActivityRows,
  ]
  const seenIds = new Set<string>()
  const allActivityRows = combinedActivityRows.filter((row) => {
    if (seenIds.has(row.id)) return false
    seenIds.add(row.id)
    return true
  })

  return (
    <>
      <div className={detailSectionStackClass}>
        <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
          <div className="min-w-0 pb-8 lg:col-span-2">
            <PortfolioStatCards activeTab={activeDashboardTab} />
          </div>

          <aside className="min-w-0 lg:col-start-2 lg:row-start-2 lg:pt-8">
            <PortfolioRewardsCards
              claimHref={claimHref}
              earnedAmount={snapshot.summary.totalEarnedAmount}
              claimableAmount={snapshot.summary.totalClaimableAmount}
              activeTab={activeDashboardTab}
              showQuickActions
            />
            {/* Desktop sidebar — Activity stays beside rewards. */}
            <section
              id="dashboard-activity"
              className="mt-10 hidden scroll-mt-24 border-t border-border pt-10 lg:block"
            >
              <h2 className="mb-5 text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                {t("Activity")}
              </h2>
              <RecentActivity rows={allActivityRows} walletId={walletId} />
            </section>
          </aside>

          <div className="min-w-0 lg:col-start-1 lg:row-start-2 lg:pt-8">
            <section>
              <div className="mb-6 mt-10 border-t border-border pt-10 md:mt-12 md:pt-12 lg:hidden">
                <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground">
                  {t("Dashboard Positions")}
                </h2>
              </div>
              <UnderlineTabStrip
                items={DASHBOARD_TABS.map((tab) => ({ id: tab.id, label: t(tab.label) }))}
                value={activeDashboardTab}
                onChange={handleDashboardTabChange}
                ariaLabel={t("Dashboard tabs")}
                className="mb-6"
                listClassName="w-max min-w-full gap-6 px-2 sm:gap-9 sm:px-0"
                tabClassName="text-[18px] font-medium tracking-[-0.01em] md:text-[18px]"
              />

              <div className="min-w-0">
                {activeDashboardTab === "wallet" ? (
                  <DashboardWalletTab walletId={walletId} />
                ) : activeDashboardTab === "rewards" ? (
                  <DashboardRewardsTab questsByTab={questsByTab} onTaskAction={(taskId) => handleTaskAction(taskId)} />
                ) : (
                  <RewardsPromoContent
                    activePromoTab={activeDashboardTab}
                    questsByTab={questsByTab}
                    onTaskAction={(taskId) => handleTaskAction(taskId)}
                    returnHref={`/dashboard?tab=${activeDashboardTab}`}
                    showRewards={false}
                  />
                )}
              </div>

              {/* Mobile — Activity sits above Learn Avana. */}
              <section className="mt-10 border-t border-border pt-10 md:mt-12 md:pt-12 lg:hidden">
                <h2 className="mb-5 text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground">
                  {t("Activity")}
                </h2>
                <RecentActivity rows={allActivityRows} walletId={walletId} />
              </section>

              <div className="mt-10 border-t border-border pt-10 pb-24 md:mt-12 md:pt-12 lg:pb-0">
                <LearnSection />
              </div>
            </section>
          </div>
        </div>
      </div>

      {activeDashboardTab === "rewards" ? (
        <MobileDetailActionBar>
          {claimHref ? (
            <Link
              href={claimHref}
              className={primaryCtaClass({ size: "compact", className: "w-full gap-2.5 font-normal [&_svg]:size-5" })}
            >
              <ActionIcon label="Claim" />
              {t("Claim rewards")}
            </Link>
          ) : (
            <button
              type="button"
              disabled
              className={primaryCtaClass({ size: "compact", disabled: true, className: "w-full" })}
            >
              {t("No rewards ready")}
            </button>
          )}
        </MobileDetailActionBar>
      ) : null}

      <RewardsEducationDialog
        open={educationOpen}
        onOpenChange={setEducationOpen}
        onComplete={async () => {
          await completeEducation()
          reloadSnapshot()
        }}
      />

      <RewardsFavoriteDialog
        open={favoriteOpen}
        onOpenChange={setFavoriteOpen}
        onFavorite={async (marketId) => {
          await favoriteMarket(marketId)
          reloadSnapshot()
        }}
      />

      <RewardsSimulateDialog open={simulateOpen} onOpenChange={setSimulateOpen} onSimulate={handleSimulate} />

      <RewardsReferralDialog
        open={referralOpen}
        onOpenChange={setReferralOpen}
        task={referralTask}
        progress={referralProgress}
        referralLink={referralLink}
        referralCode={referralCode}
        onEnsureProfile={async () => {
          const profile = await createReferralCode()
          setReferralLink(profile.referralLink)
          setReferralCode(profile.referralCode)
        }}
        onCopyLink={async () => {
          const profile = await createReferralCode()
          setReferralLink(profile.referralLink)
          setReferralCode(profile.referralCode)
          await recordReferralLinkCopied()
          if (typeof navigator !== "undefined" && navigator.clipboard) {
            await navigator.clipboard.writeText(profile.referralLink)
          }
          reloadSnapshot()
        }}
        onSendInvite={async () => {
          await runReferralSandboxStep("invite")
          reloadSnapshot()
        }}
        onActivateNext={async () => {
          await runReferralActivations()
          reloadSnapshot()
        }}
        onMarkFunded={async () => {
          await runReferralSandboxStep("fund")
          reloadSnapshot()
        }}
        onClaim={async () => {
          if (!referralTaskId || isClaiming) return
          setIsClaiming(true)
          try {
            await persistRewardsClaim([referralTaskId])
            reloadSnapshot()
          } finally {
            setIsClaiming(false)
          }
        }}
      />
    </>
  )
}
