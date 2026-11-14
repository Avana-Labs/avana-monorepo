"use client"

import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { CarouselArrowButtons, useOverflowCarousel } from "@/app/components/carousel-arrow-buttons"
import { TokenIcon } from "@/app/components/token-icon"
import { Button } from "@/components/ui/button"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { useUmbrellaSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import { cn } from "@/lib/utils"
import { useCooldownCountdown } from "../use-cooldown-countdown"

type CooldownStatus = "cooling" | "ready" | "expired"

type CooldownCard = {
  id: UmbrellaMarketId
  asset: string
  symbol: string
  coverage: string
  cooldownStatus: CooldownStatus
  cooldownRemainingFallback: string
  removesInFallback: string
  cooldownEndsAt: number | undefined
  withdrawalWindowEndsAt: number | undefined
}

function statusLabelKey(status: CooldownStatus): string {
  if (status === "ready") return "Withdrawal ready"
  if (status === "expired") return "Cooldown expired"
  return "In cooldown"
}

function CooldownCardView({ card }: { card: CooldownCard }) {
  const { t } = useTranslation()
  const cooldown = useCooldownCountdown(card.cooldownEndsAt)
  const withdrawal = useCooldownCountdown(card.withdrawalWindowEndsAt)
  const cooldownLabel =
    card.cooldownStatus === "cooling"
      ? card.cooldownEndsAt
        ? cooldown.remainingLabel
        : card.cooldownRemainingFallback
      : card.cooldownStatus === "expired"
        ? t("Expired")
        : t("Ready")
  const removesLabel =
    card.cooldownStatus === "ready"
      ? card.withdrawalWindowEndsAt && withdrawal.remainingMs > 0
        ? t("{time} left").replace("{time}", withdrawal.remainingLabel)
        : card.removesInFallback
      : card.cooldownStatus === "expired"
        ? t("Closed")
        : card.cooldownEndsAt
          ? cooldown.remainingLabel
          : card.removesInFallback

  const removesTone = card.cooldownStatus === "ready" ? "text-success" : undefined

  const statusTone =
    card.cooldownStatus === "expired"
      ? "text-danger"
      : card.cooldownStatus === "ready"
        ? "text-success"
        : "text-muted-foreground"

  const ctaHref =
    card.cooldownStatus === "expired"
      ? actionPagePath("umbrella", "cooldown", { market: card.id, return: "/umbrella" })
      : actionPagePath("umbrella", "unstake", { market: card.id, return: "/umbrella" })
  const ctaLabel = card.cooldownStatus === "expired" ? t("Restart cooldown") : t("Remove")
  const ctaDisabled = card.cooldownStatus === "cooling"

  return (
    <div className="rounded-radius-md bg-card px-4 py-4">
      <div className="flex min-w-0 items-center gap-2.5">
        <TokenIcon symbol={card.symbol} size="table" />
        <div className="min-w-0">
          <div className="truncate text-[15px] font-semibold tracking-[-0.03em]">{card.asset}</div>
          <div className="truncate text-[13px] text-muted-foreground">{card.coverage}</div>
        </div>
      </div>

      <div className={cn("mt-3 text-[12px] font-semibold uppercase tracking-wide", statusTone)}>
        {t(statusLabelKey(card.cooldownStatus))}
      </div>

      <div className="mt-2 grid grid-cols-2 gap-2">
        <div>
          <div className="text-[13px] text-muted-foreground">{t("Cooldown")}</div>
          <div className="mt-1 text-[20px] font-semibold tracking-[-0.04em] tabular-nums">{cooldownLabel}</div>
        </div>
        <div>
          {/* Expired: the unstake window has passed ("Removes in: Restart" read wrong). */}
          <div className="text-[13px] text-muted-foreground">
            {card.cooldownStatus === "expired" ? t("Unstake window") : t("Removes in")}
          </div>
          <div className={cn("mt-1 text-[20px] font-semibold tracking-[-0.04em] tabular-nums", removesTone)}>
            {removesLabel}
          </div>
        </div>
      </div>

      {ctaDisabled ? (
        <Button type="button" size="sm" variant="brand" className="mt-4 h-10 w-full gap-2" disabled>
          <ActionIcon label={ctaLabel} />
          {ctaLabel}
        </Button>
      ) : (
        <Button asChild size="sm" variant="brand" className="mt-4 h-10 w-full gap-2">
          <Link href={ctaHref}>
            <ActionIcon label={ctaLabel} />
            {ctaLabel}
          </Link>
        </Button>
      )}
    </div>
  )
}

export function UmbrellaCooldown() {
  const { t } = useTranslation()
  const { scrollerRef, canPrev, canNext, scrollByCard } = useOverflowCarousel()
  const umbrella = useUmbrellaSessionContext()
  const coolingPositions: CooldownCard[] = umbrella.marketOrder
    .filter((id) => umbrella.positions[id].cooldownStatus !== "idle")
    .map((id) => {
      const market = umbrella.markets[id]
      const position = umbrella.positions[id]
      return {
        id,
        asset: market.asset,
        symbol: market.symbol,
        coverage: market.coverage,
        cooldownStatus: position.cooldownStatus as CooldownStatus,
        cooldownRemainingFallback: position.cooldownRemaining,
        removesInFallback: position.removesIn,
        cooldownEndsAt: position.cooldownEndsAt,
        withdrawalWindowEndsAt: position.withdrawalWindowEndsAt,
      }
    })
  if (coolingPositions.length === 0) return null

  return (
    <section>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
            {t("Umbrella Cooldown")}
          </h2>
          <p className="mt-2 text-[13px] text-muted-foreground">
            {t("Cooldown")}: 20 days · {t("Unstake window")}: 2 days
          </p>
        </div>
        {canPrev || canNext ? (
          <CarouselArrowButtons
            canPrev={canPrev}
            canNext={canNext}
            onPrev={() => scrollByCard(-1)}
            onNext={() => scrollByCard(1)}
            prevLabel={t("Previous cooldown")}
            nextLabel={t("Next cooldown")}
          />
        ) : null}
      </div>

      <div className="overflow-hidden">
        <div
          ref={scrollerRef}
          className="overflow-x-auto pb-1 [scrollbar-width:none] snap-x snap-mandatory [&::-webkit-scrollbar]:hidden"
        >
          <ul className="flex w-full gap-3">
            {coolingPositions.map((position) => (
              <li
                key={position.id}
                data-carousel-card
                className="w-[min(280px,85%)] shrink-0 snap-start sm:w-[calc((100%-0.75rem)/2)] lg:w-[calc((100%-1.5rem)/3)]"
              >
                <CooldownCardView card={position} />
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  )
}
