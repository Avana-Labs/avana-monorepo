"use client"

import { useEffect, useRef, useState, type ReactNode } from "react"
import Link from "next/link"
import { cn } from "@/lib/utils"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TRANSACT_ACCESS_HREF, useTransactAccessCta } from "@/app/lib/transact-access"

const DETAIL_PAGE_MAX_W = "max-w-[1152px]"

/** Vertical stack of detail page sections with horizontal dividers centered between siblings. */
export const detailSectionStackClass =
  "flex flex-col [&>*:not(:last-child)]:pb-10 [&>*+*]:border-t [&>*+*]:border-border [&>*+*]:pt-10"

/** Larger spacing variant for deferred analytics blocks below the fold. */
export const detailAnalyticsStackClass =
  "flex flex-col [&>*:not(:last-child)]:pb-10 md:[&>*:not(:last-child)]:pb-12 [&>*+*]:border-t [&>*+*]:border-border [&>*+*]:pt-10 md:[&>*+*]:pt-12"

/** Top divider centered between the about block and analytics sections. */
export const detailAnalyticsSectionClass = "mt-10 border-t border-border pt-10 md:mt-12 md:pt-12"

export function DetailPageWidth({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("mx-auto", DETAIL_PAGE_MAX_W, className)}>{children}</div>
}

/**
 * How far below the viewport the deferred analytics stack mounts. Its sections are lazy chunks that
 * each pop in at full height; mounting ~a screen early keeps that growth off screen, so content the
 * reader is looking at never jumps. The stack starts 2.5k–3k px down, so this never mounts on load.
 */
export const DEFERRED_DETAIL_ROOT_MARGIN = "1000px 0px"

/** Skeleton for the deferred analytics stack, before it mounts and while its lazy module loads. */
export function DeferredDetailPlaceholder({ className = "min-h-[120px]" }: { className?: string }) {
  return (
    <div aria-hidden className={cn("space-y-3 rounded-radius-md p-2", className)}>
      <div className="h-4 w-1/3 animate-pulse rounded bg-muted" />
      <div className="h-20 w-full animate-pulse rounded bg-muted/70" />
      <div className="h-20 w-full animate-pulse rounded bg-muted/50" />
    </div>
  )
}

export function DeferredDetailContent({
  children,
  className,
  placeholderClassName = "min-h-[120px]",
}: {
  children: ReactNode
  className?: string
  placeholderClassName?: string
}) {
  const markerRef = useRef<HTMLDivElement | null>(null)
  const [shouldMount, setShouldMount] = useState(() => process.env.NODE_ENV === "test")

  useEffect(() => {
    if (shouldMount) return
    const marker = markerRef.current
    if (!marker || typeof IntersectionObserver === "undefined") {
      setShouldMount(true)
      return
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry?.isIntersecting) return
        setShouldMount(true)
        observer.disconnect()
      },
      { rootMargin: DEFERRED_DETAIL_ROOT_MARGIN, threshold: 0 },
    )
    observer.observe(marker)
    return () => observer.disconnect()
  }, [shouldMount])

  return (
    <div ref={markerRef} className={className}>
      {shouldMount ? children : <DeferredDetailPlaceholder className={placeholderClassName} />}
    </div>
  )
}

export function MobileDetailActionBar({ children, className }: { children: ReactNode; className?: string }) {
  const { t } = useTranslation()
  // A guest (or a wallet still onboarding) gets ONE CTA to the dashboard onboarding in place of
  // the product actions, matching the desktop sidebar.
  const accessCta = useTransactAccessCta()
  const accessLabel = accessCta.label
  return (
    <div
      className={cn(
        "fixed inset-x-0 bottom-0 z-30 border-t border-border bg-background/95 px-4 pb-[calc(0.75rem+env(safe-area-inset-bottom))] pt-3 backdrop-blur supports-[backdrop-filter]:bg-background/80 lg:hidden",
        !accessLabel && className,
      )}
    >
      {accessLabel ? (
        <Link
          href={TRANSACT_ACCESS_HREF}
          onClick={accessCta.onClick}
          className={primaryCtaClass({ size: "compact", className: "w-full font-normal" })}
        >
          {t(accessLabel)}
        </Link>
      ) : (
        children
      )}
    </div>
  )
}

const DETAIL_PAGE_NOTICES = {
  borrow:
    "Borrowing against LP tokens involves risk, including liquidation if market conditions move against your position. Avana does not custody your funds, rehypothecate LP positions, or alter how your liquidity operates on underlying AMMs. Loan terms, interest rates, and collateral values are enforced on-chain using transparent oracle systems and automated risk parameters. You remain in full control of your position at all times and can repay or adjust collateral whenever you choose. Only borrow amounts you are comfortable maintaining through market volatility.",
  lend: "Supplying assets involves risk, including smart-contract, oracle, and liquidity risk if market conditions change. Avana does not custody your funds or alter how your deposits operate in the lending market. Supply rates, utilization, and available liquidity are enforced on-chain using transparent oracle systems and automated risk parameters. You remain in full control of your position at all times and can withdraw available liquidity whenever market conditions allow. Only supply amounts you are comfortable keeping deployed through changes in utilization and demand.",
  multiply:
    "Opening a multiply position involves risk, including liquidation if market conditions move against your leveraged loop. Avana does not custody your funds or alter how the underlying collateral and debt legs operate. Leverage limits, interest rates, and collateral values are enforced on-chain using transparent oracle systems and automated risk parameters. You remain in full control of your position at all times and can deleverage, repay, or close whenever you choose. Only use leverage you are comfortable maintaining through market volatility.",
} as const

type DetailPageNoticeProduct = keyof typeof DETAIL_PAGE_NOTICES

export function DetailPageNotice({
  className,
  product = "borrow",
}: {
  className?: string
  product?: DetailPageNoticeProduct
}) {
  return (
    <section role="note" aria-labelledby="risk-disclosures-heading" className={cn("mt-12", className)}>
      <h2
        id="risk-disclosures-heading"
        className="text-[18px] font-medium tracking-[-0.02em] text-foreground md:text-[20px]"
      >
        Risk Disclosures
      </h2>
      <p className="mt-3 text-sm leading-6 text-muted-foreground">{DETAIL_PAGE_NOTICES[product]}</p>
    </section>
  )
}
