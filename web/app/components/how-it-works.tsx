"use client"

import { useState } from "react"
import { CircleHelp } from "@/app/components/icons"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type HowItWorksTopic = "lend" | "borrow"

type HowItWorksSection = { heading: string; body: string }
type HowItWorksContent = {
  title: string
  intro: string
  sections: HowItWorksSection[]
  footnote?: string
}

/**
 * Teaching content for the "How it works" explainers. Kept as plain (English)
 * copy rather than t() keys: it is long-form educational text and localizing it
 * is a separate translation pass — the trigger label itself IS localized.
 */
const HOW_IT_WORKS: Record<HowItWorksTopic, HowItWorksContent> = {
  lend: {
    title: "How Lending works",
    intro:
      "Supplying (lending) an asset earns you yield paid by borrowers. Your deposit joins a shared liquidity pool and starts earning immediately.",
    sections: [
      {
        heading: "How you earn",
        body: "Borrowers pay interest on what they borrow, and that interest flows to suppliers. The supply APY moves with utilization — the more of the pool that's borrowed, the higher the rate.",
      },
      {
        heading: "Access to your funds",
        body: "You can withdraw supplied assets whenever there is available (un-borrowed) liquidity in the market. High utilization can temporarily limit how much you can pull out until borrowers repay.",
      },
      {
        heading: "Risks",
        body: "Lending carries smart-contract, oracle, and liquidity risk. Rates and available liquidity change with market demand — only supply amounts you're comfortable keeping deployed.",
      },
    ],
  },
  borrow: {
    title: "How Borrowing works",
    intro:
      "Borrowing lets you take a loan against collateral you deposit, without selling it. You keep exposure to your collateral while unlocking liquidity.",
    sections: [
      {
        heading: "Collateral & health factor",
        body: "Your borrowing power is a fraction of your collateral's value (its LTV). A health factor tracks how safe your position is — it falls when collateral drops in price or you borrow more.",
      },
      {
        heading: "Liquidation",
        body: "If your health factor falls too low, part of your collateral can be liquidated to repay the loan and restore safety. Keeping a buffer above the minimum protects you through volatility.",
      },
      {
        heading: "Interest & repayment",
        body: "Interest accrues on your debt at a variable rate. You can repay part or all of the loan at any time, and add or withdraw collateral to manage your health factor.",
      },
    ],
  },
}

/**
 * "How it works" pill — a reusable teaching trigger. Opens a popup styled like the
 * header search dialog (same card size + backdrop blur) with per-topic explainer copy.
 */
export function HowItWorks({ topic, className }: { topic: HowItWorksTopic; className?: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const content = HOW_IT_WORKS[topic]

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={cn(
          "inline-flex shrink-0 items-center gap-1.5 rounded-full border border-border px-3 py-1.5 text-[13px] font-medium text-foreground transition-colors hover:bg-hover",
          className,
        )}
      >
        {t("How it works")}
        <CircleHelp className="size-4 text-muted-foreground" />
      </button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[min(620px,calc(100dvh-96px))] w-full max-w-[600px] gap-0 overflow-hidden rounded-radius-xl border-border bg-background p-0 shadow-[0_24px_80px_rgba(15,23,42,0.22)] sm:w-[calc(100vw-24px)] [&>button]:right-3.5 [&>button]:top-3.5 [&>button]:rounded-full">
          <div className="border-b border-border px-5 py-4 pr-12">
            <DialogTitle className="text-[18px] font-semibold tracking-[-0.02em] text-foreground">
              {content.title}
            </DialogTitle>
            <DialogDescription className="mt-1.5 text-[14px] leading-6 text-muted-foreground">
              {content.intro}
            </DialogDescription>
          </div>

          <div className="max-h-[min(460px,calc(100dvh-220px))] space-y-4 overflow-y-auto px-5 py-4">
            {content.sections.map((section) => (
              <div key={section.heading}>
                <div className="text-[14px] font-semibold text-foreground">{section.heading}</div>
                <p className="mt-1 text-[14px] leading-6 text-muted-foreground">{section.body}</p>
              </div>
            ))}
            {content.footnote ? (
              <p className="border-t border-border pt-3 text-[12px] leading-5 text-muted-foreground">
                {content.footnote}
              </p>
            ) : null}
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
