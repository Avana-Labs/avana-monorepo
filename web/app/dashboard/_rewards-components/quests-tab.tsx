"use client"

import Image from "next/image"
import { useEffect, useState } from "react"
import {
  ArrowRight,
  Droplets,
  Flame,
  Layers3,
  Link2,
  LockKeyhole,
  Orbit,
  Repeat2,
  Rocket,
  ShieldCheck,
  Sparkles,
  Target,
  Trophy,
  Wallet,
} from "@/app/components/icons"
import { CarouselArrowButtons, useOverflowCarousel } from "@/app/components/carousel-arrow-buttons"
import { type RewardsPromoTabId, type RewardsQuestIconId, type RewardsQuest } from "@/app/lib/data/rewards/catalog"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { UnderlineTabStrip } from "@/app/components/tab-primitives"
import { Card } from "@/components/ui/card"
import { LendAccountSection } from "./lend-account-section"
import { BorrowAccountSection } from "./borrow-account-section"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const QUEST_ICON_MAP: Record<RewardsQuestIconId, typeof Wallet> = {
  droplets: Droplets,
  flame: Flame,
  layers3: Layers3,
  link2: Link2,
  lockKeyhole: LockKeyhole,
  orbit: Orbit,
  repeat2: Repeat2,
  rocket: Rocket,
  shieldCheck: ShieldCheck,
  sparkles: Sparkles,
  target: Target,
  trophy: Trophy,
  wallet: Wallet,
}

function AvaCoin({ size = 20 }: { size?: number }) {
  return (
    <Image
      src="/asset-icons/ava.png"
      alt=""
      width={size}
      height={size}
      sizes={`${size}px`}
      className="shrink-0 object-contain"
      style={{ width: size, height: size }}
      aria-hidden
    />
  )
}

function AvanaQuestCard({
  quest,
  onTaskAction,
}: {
  quest: RewardsQuest & { status?: string; progressLabel?: string }
  onTaskAction: (taskId: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const Icon = QUEST_ICON_MAP[quest.iconId]
  const isClaimable = quest.status === "claimable"
  const isClaimed = quest.status === "claimed"
  const isDisabled = isClaimed || quest.status === "expired" || quest.cta === t("Waiting")
  const canAct =
    isClaimable || ((quest.status === "available" || quest.status === "in_progress") && quest.cta !== t("Waiting"))
  const rewardValue = quest.reward.replace(/[^\d.,]/g, "")
  const metaLine = "progressLabel" in quest && quest.progressLabel ? quest.progressLabel : quest.description

  return (
    <div className="flex h-full flex-col">
      {/* Prize illustration sits on its own above the card — no panel, no overlap. */}
      <div className="flex justify-center pb-1">
        {quest.image ? (
          <Image
            src={quest.image}
            alt=""
            width={192}
            height={192}
            sizes="96px"
            loading="lazy"
            className={`h-24 w-24 object-contain drop-shadow-md transition duration-300 ${isClaimed ? "opacity-40 grayscale" : ""}`}
          />
        ) : (
          <div className="flex h-24 w-24 items-center justify-center">
            <Icon className="h-14 w-14 text-brand" strokeWidth={1.3} />
          </div>
        )}
      </div>

      <Card className="flex flex-1 flex-col items-center rounded-radius-md border border-border/60 bg-card p-3 text-center shadow-none">
        <h3
          className={`line-clamp-2 text-[13px] font-normal leading-4 tracking-[-0.02em] text-foreground ${isClaimed ? "opacity-55" : ""}`}
        >
          {t(quest.title)}
        </h3>
        <p className={`mt-1 line-clamp-1 text-[13px] leading-4 text-muted-foreground ${isClaimed ? "opacity-55" : ""}`}>
          {t(metaLine)}
        </p>

        {/* The prize — coin + amount, the hero of the card. */}
        <div className={`mt-2.5 flex items-center justify-center gap-1.5 ${isClaimed ? "opacity-55" : ""}`}>
          <AvaCoin size={22} />
          <span className="font-data text-[22px] font-normal leading-none tracking-tight text-foreground">
            {rewardValue}
          </span>
        </div>

        <button
          type="button"
          onClick={() => {
            if (canAct) {
              void onTaskAction(quest.id)
            }
          }}
          disabled={isDisabled}
          className={`mt-3 inline-flex h-9 w-full items-center justify-center gap-1.5 rounded-radius-sm px-3 text-[13px] font-normal transition-colors [&_svg]:size-4 ${
            isClaimable
              ? "bg-brand text-white shadow-sm hover:bg-brand/90"
              : isDisabled
                ? "bg-muted/60 text-muted-foreground"
                : "border border-brand/25 bg-brand/5 text-foreground hover:bg-brand/10"
          }`}
        >
          {t(quest.cta)}
          {!isDisabled ? <ArrowRight /> : null}
        </button>

        {quest.expiration ? (
          <div className="mt-2 text-[10px] text-muted-foreground">
            {t("Expiration")} · {quest.expiration}
          </div>
        ) : null}
      </Card>
    </div>
  )
}

function RewardsPromoPanel({
  promoTabs,
  questsByTab,
  onTaskAction,
}: {
  promoTabs: ReadonlyArray<{ id: RewardsPromoTabId; label: string }>
  questsByTab: Record<RewardsPromoTabId, RewardsQuest[]>
  onTaskAction: (taskId: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const [activePromoTab, setActivePromoTab] = useState<RewardsPromoTabId>(promoTabs[0]?.id ?? "getting-started")

  useEffect(() => {
    const activateFromHash = () => {
      const hash = window.location.hash.slice(1)
      if (hash === "dashboard-borrow-account") setActivePromoTab("borrow")
      if (hash === "dashboard-lend-account") setActivePromoTab("lend")
    }

    activateFromHash()
    window.addEventListener("hashchange", activateFromHash)
    return () => window.removeEventListener("hashchange", activateFromHash)
  }, [])

  return (
    <section className="space-y-6">
      <UnderlineTabStrip
        items={promoTabs.map((tab) => ({ id: tab.id, label: t(tab.label) }))}
        value={activePromoTab}
        onChange={setActivePromoTab}
        ariaLabel={t("Rewards quest categories")}
        listClassName="w-max min-w-full gap-6 px-2 sm:gap-9 sm:px-0"
      />

      <RewardsPromoContent activePromoTab={activePromoTab} questsByTab={questsByTab} onTaskAction={onTaskAction} />
    </section>
  )
}

export function RewardsPromoContent({
  activePromoTab,
  questsByTab,
  onTaskAction,
  returnHref = "/dashboard",
  showRewards = true,
}: {
  activePromoTab: RewardsPromoTabId
  questsByTab: Record<RewardsPromoTabId, RewardsQuest[]>
  onTaskAction: (taskId: string) => Promise<unknown>
  returnHref?: string
  showRewards?: boolean
}) {
  const { t } = useTranslation()
  const activeQuests = questsByTab[activePromoTab] ?? []
  const rewardsSectionTitle =
    activePromoTab === "lend"
      ? t("Lend Rewards")
      : activePromoTab === "borrow"
        ? t("Borrow Rewards")
        : null

  return (
    <div className={detailSectionStackClass}>
      {activePromoTab === "lend" ? <LendAccountSection returnHref={returnHref} /> : null}
      {activePromoTab === "borrow" ? <BorrowAccountSection returnHref={returnHref} /> : null}

      {showRewards && activeQuests.length > 0 ? (
        <RewardsQuestSection title={rewardsSectionTitle} quests={activeQuests} onTaskAction={onTaskAction} />
      ) : showRewards ? (
        <p className="text-[13px] text-muted-foreground">{t("No quests here yet — check back soon.")}</p>
      ) : null}
    </div>
  )
}

export function RewardsQuestSection({
  title,
  quests,
  onTaskAction,
}: {
  title?: string | null
  quests: Array<RewardsQuest & { status?: string; progressLabel?: string }>
  onTaskAction: (taskId: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const { scrollerRef, canPrev, canNext, scrollByCard } = useOverflowCarousel()

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        {title ? (
          <div>
            <h2 className="text-[16px] font-normal tracking-tight text-foreground md:text-[18px]">{title}</h2>
            <p className="mt-1 text-[13px] text-muted-foreground">
              {t("{count} rewards").replace("{count}", String(quests.length))}
            </p>
          </div>
        ) : (
          <span />
        )}
        {canPrev || canNext ? (
          <CarouselArrowButtons
            canPrev={canPrev}
            canNext={canNext}
            onPrev={() => scrollByCard(-1)}
            onNext={() => scrollByCard(1)}
            prevLabel={t("Previous rewards")}
            nextLabel={t("Next rewards")}
          />
        ) : null}
      </div>
      <div className="overflow-hidden">
        <div
          ref={scrollerRef}
          className="overflow-x-auto pb-1 [scrollbar-width:none] snap-x snap-mandatory [&::-webkit-scrollbar]:hidden"
        >
          <ul className="flex w-full gap-3">
            {quests.map((quest) => (
              <li
                key={quest.id}
                data-carousel-card
                className="w-[min(220px,72%)] shrink-0 snap-start sm:w-[calc((100%-0.75rem)/2)] xl:w-[calc((100%-1.5rem)/3)]"
              >
                <AvanaQuestCard quest={quest} onTaskAction={onTaskAction} />
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  )
}

/** Rewards quests surface: Avana-specific onboarding and challenge task tabs. */
export function QuestsTab({
  promoTabs,
  questsByTab,
  onTaskAction,
}: {
  promoTabs: ReadonlyArray<{ id: RewardsPromoTabId; label: string }>
  questsByTab: Record<RewardsPromoTabId, RewardsQuest[]>
  onTaskAction: (taskId: string) => Promise<unknown>
}) {
  return (
    <div className="space-y-6">
      <RewardsPromoPanel promoTabs={promoTabs} questsByTab={questsByTab} onTaskAction={onTaskAction} />
    </div>
  )
}
