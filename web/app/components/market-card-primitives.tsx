"use client"

import type { HTMLAttributes, ReactNode } from "react"
import { cn } from "@/lib/utils"

export function MarketMobileCard({
  children,
  className,
  clickable = false,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  children: ReactNode
  className?: string
  clickable?: boolean
}) {
  return (
    <div
      className={cn(
        // Use the same solid, rounded surface as Dashboard snapshot cards. Keep
        // touch cards free of a sticky hover state.
        "rounded-radius-md border-0 bg-card px-4 py-3 shadow-none",
        clickable ? "cursor-pointer" : "",
        className,
      )}
      {...props}
    >
      {children}
    </div>
  )
}

export function MarketMobileCardHeader({
  identity,
  metric,
  className,
}: {
  identity: ReactNode
  metric?: ReactNode
  className?: string
}) {
  return (
    <div className={cn("flex items-start justify-between gap-3", className)}>
      <div className="min-w-0">{identity}</div>
      {metric ? <div className="shrink-0 text-right">{metric}</div> : null}
    </div>
  )
}

export function MarketMobileIdentityText({
  title,
  subtitle,
  className,
}: {
  title: ReactNode
  subtitle?: ReactNode
  className?: string
}) {
  return (
    <div className={cn("min-w-0", className)}>
      <div className="truncate text-[15px] font-normal leading-5 tracking-normal text-foreground dark:text-white">
        {title}
      </div>
      {subtitle ? (
        <div className="mt-0.5 truncate text-[13px] font-normal leading-4 tracking-normal text-muted-foreground dark:text-white/48">
          {subtitle}
        </div>
      ) : null}
    </div>
  )
}

export function MarketMobileSupportingValue({ children }: { children: ReactNode }) {
  return <span className="ml-2 text-[13px] font-normal tracking-normal text-muted-foreground">{children}</span>
}

export function MarketMobileMetric({
  value,
  label,
  valueClassName,
}: {
  value: ReactNode
  label: ReactNode
  valueClassName?: string
}) {
  return (
    <>
      <div
        className={cn("font-data text-[18px] font-normal tabular-nums text-foreground dark:text-white", valueClassName)}
      >
        {value}
      </div>
      <div className="mt-0.5 text-[13px] font-normal leading-4 tracking-normal text-muted-foreground">{label}</div>
    </>
  )
}

/** Stat rows under the card header. Owns the header gap (12px) so every card spaces it the same. */
export function MarketMobileStatList({ children, className }: { children: ReactNode; className?: string }) {
  return <dl className={cn("mt-3 divide-y divide-border leading-5", className)}>{children}</dl>
}

export function MarketMobileStatRow({
  label,
  value,
  valueClassName,
}: {
  label: ReactNode
  value: ReactNode
  valueClassName?: string
}) {
  return (
    <div className="flex items-center justify-between gap-3 py-2.5">
      <dt className="text-[13px] text-muted-foreground">{label}</dt>
      <dd
        className={cn(
          "font-data text-[15px] font-normal tabular-nums whitespace-nowrap",
          valueClassName ?? "text-foreground",
        )}
      >
        {value}
      </dd>
    </div>
  )
}

export function MarketMobileActionFooter({
  children,
  columns = 2,
  className,
}: {
  children: ReactNode
  /** Always prefer 2 equal CTAs so product mobile cards share one chrome. */
  columns?: 1 | 2 | 3
  className?: string
}) {
  return (
    <div
      className={cn(
        "mt-4 grid gap-2 [&>*]:min-w-0 [&>a]:mt-0 [&>button]:mt-0",
        columns === 1 ? "grid-cols-1" : columns === 2 ? "grid-cols-2" : "grid-cols-3",
        className,
      )}
    >
      {children}
    </div>
  )
}

/** Shared mobile CTA chrome — matches Lend Add / Withdraw. */
export const MARKET_MOBILE_CTA_CLASS =
  "h-11 w-full gap-2.5 rounded-radius-sm px-4 text-[14px] font-normal [&_svg]:size-[18px]"

export function MarketMobilePrimaryAction({
  children,
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode; className?: string }) {
  return (
    <button
      type="button"
      className={cn(
        "mt-4 inline-flex h-11 w-full items-center justify-center gap-2.5 rounded-radius-sm bg-brand px-4 text-center text-[14px] font-normal leading-5 text-white shadow-elev-1 transition-colors hover:bg-brand/90 active:bg-brand/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-1 disabled:!opacity-100 disabled:bg-brand-soft disabled:text-brand-soft-foreground [&_svg]:size-[18px] [&_svg]:shrink-0",
        className,
      )}
      {...props}
    >
      {children}
    </button>
  )
}

export function MarketMobileSecondaryAction({
  children,
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode; className?: string }) {
  return (
    <button
      type="button"
      className={cn(
        "inline-flex h-11 flex-1 items-center justify-center gap-2.5 rounded-radius-sm border border-border bg-surface-raised px-4 text-center text-[14px] font-normal leading-5 text-foreground shadow-elev-1 transition-colors hover:bg-surface-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-1 [&_svg]:size-[18px] [&_svg]:shrink-0",
        className,
      )}
      {...props}
    >
      {children}
    </button>
  )
}
