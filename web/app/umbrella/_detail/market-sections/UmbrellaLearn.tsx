"use client"

import { Circle, Coins, ShieldCheck, Target, Umbrella, Unlock } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const learnCards = [
  {
    title: "Hub + reserve coverage",
    body: "Coverage is defined for a specific Hub reserve and covers eligible deficits from every Spoke borrowing that reserve, including credit-line draws.",
    icon: ShieldCheck,
  },
  {
    title: "First-loss protection",
    body: "The Deficit Offset absorbs the first layer of loss. Only the residual deficit beyond that offset can reach staked Umbrella coverage.",
    icon: Umbrella,
  },
  {
    title: "Independent underwriting",
    body: "Target liquidity and reward emissions reflect reserve risk, economics, opportunity cost, and the slashing and lockup risk accepted by coverage providers.",
    icon: Target,
  },
  {
    title: "Dynamic rewards",
    body: "Your APY combines base supply yield and reward emissions for keeping capital available as coverage while the position stays active.",
    icon: Coins,
  },
  {
    title: "Cooldown",
    body: "Start a 20-day cooldown before withdrawing. During cooldown, the position keeps earning and remains slashable.",
    icon: Circle,
  },
  {
    title: "Withdrawal window",
    body: "When cooldown ends, a 2-day withdrawal window opens. Unstake within it, or restart cooldown before exiting.",
    icon: Unlock,
  },
]

export function UmbrellaLearn() {
  const { t } = useTranslation()
  return (
    <section>
      <div className="mb-6 flex items-center justify-between">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
          {t("Learn Umbrella")}
        </h2>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {learnCards.map((card) => (
          <article key={card.title} className="rounded-radius-md bg-card px-4 py-4">
            <card.icon className="h-6 w-6 text-brand" />
            <h3 className="mt-4 text-[17px] font-semibold tracking-[-0.03em]">{t(card.title)}</h3>
            <p className="mt-2 text-[14px] leading-6 text-muted-foreground">{t(card.body)}</p>
          </article>
        ))}
      </div>
    </section>
  )
}
