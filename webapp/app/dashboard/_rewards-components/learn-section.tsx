"use client"

import type { LucideIcon } from "@/app/components/icons"
import { Compass, GraduationCap, Layers3, Repeat, ShieldCheck, Unlock } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type LearnCard = {
  title: string
  body: string
  icon: LucideIcon
}

/**
 * "Learn Avana" explainer cards — a full-card teaching layout (icon + title + body, no
 * links). Copy is drawn from the Avana
 * FAQ topics (keep your LP position, borrowing power, drawdowns, isolated risk,
 * repay/close) plus a product overview. Kept as plain (English) copy — long-form
 * teaching content; only the section heading is localized.
 */
const LEARN_CARDS: LearnCard[] = [
  {
    title: "Keep your LP position",
    body: "Borrow against your LP tokens without selling or exiting. Your liquidity keeps earning trading fees while you unlock cash to use elsewhere.",
    icon: Unlock,
  },
  {
    title: "What you can borrow",
    body: "Your borrowing power is a share of your collateral's value, set by each pool's loan-to-value. A health factor shows how much room you have before liquidation.",
    icon: GraduationCap,
  },
  {
    title: "If your LP value drops",
    body: "As collateral falls, your health factor drops with it. If it reaches the limit, part of your collateral is liquidated to repay the loan — keeping a buffer protects your position.",
    icon: ShieldCheck,
  },
  {
    title: "Isolated risk",
    body: "Every pool is risk-scored on its own and kept isolated. Exposure stays contained to the market you use, so trouble in one pool doesn't cascade into your other positions.",
    icon: Layers3,
  },
  {
    title: "Repay or close anytime",
    body: "Repay part or all of your loan whenever you want, or close the position entirely. Add or withdraw collateral at any time to manage your health factor.",
    icon: Repeat,
  },
  {
    title: "Ways to use Avana",
    body: "Lend to earn yield, borrow against LP collateral, or swap tokens in one place.",
    icon: Compass,
  },
]

export function LearnSection() {
  const { t } = useTranslation()

  return (
    <section className="min-w-0">
      <div className="mb-6 flex items-center justify-between">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
          {t("Learn Avana")}
        </h2>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {LEARN_CARDS.map((card) => (
          <article key={card.title} className="rounded-radius-md bg-card px-4 py-4">
            <card.icon className="h-6 w-6 text-brand" strokeWidth={1.75} />
            <h3 className="mt-4 text-[18px] font-normal tracking-[-0.01em]">{card.title}</h3>
            <p className="mt-2 text-[14px] leading-6 text-muted-foreground">{card.body}</p>
          </article>
        ))}
      </div>
    </section>
  )
}
