"use client"

import * as React from "react"
import { Card, CardContent } from "@/components/ui/card"
import { cn } from "@/lib/utils"

type SectionCardProps = {
  title?: React.ReactNode
  subtitle?: React.ReactNode
  rightSlot?: React.ReactNode
  children: React.ReactNode
  className?: string
  bodyClassName?: string
  chrome?: "card" | "plain"
  /** Render the wrapper as a landmark. */
  as?: "section" | "div"
  id?: string
}

export function SectionCardPrimaryMetric({ className, ...props }: React.ComponentPropsWithoutRef<"span">) {
  return (
    <span
      className={cn(
        "font-data text-[26px] font-medium leading-none tabular-nums text-foreground md:text-[30px]",
        className,
      )}
      {...props}
    />
  )
}

export function SectionCardSupportingLabel({ className, ...props }: React.ComponentPropsWithoutRef<"span">) {
  return <span className={cn("text-[12px] font-normal leading-4 text-muted-foreground", className)} {...props} />
}

export function SectionCardCopy({ className, ...props }: React.ComponentPropsWithoutRef<"p">) {
  return <p className={cn("text-[15px] leading-[1.6] text-muted-foreground md:text-[16px]", className)} {...props} />
}

export function SectionCardActions({ className, ...props }: React.ComponentPropsWithoutRef<"div">) {
  return (
    <div className={cn("mt-4 flex flex-wrap items-center gap-2 border-t border-border pt-4", className)} {...props} />
  )
}

/**
 * Canonical section shell used across `/multiply`, `/lend`, and now the borrow
 * detail pages. Title sits OUTSIDE the Card (matches `HotMarkets`,
 * `MyInvestments`) and the Card itself uses the soft `border-border/40 bg-card/50`
 * surface with `shadow-none`. Body padding defaults to `p-6`; tables should
 * pass `bodyClassName="p-0"` so rows can reach the gutter.
 */
export function SectionCard({
  title,
  subtitle,
  rightSlot,
  children,
  className,
  bodyClassName = "p-6",
  chrome = "card",
  as: Tag = "section",
  id,
}: SectionCardProps) {
  const hasHeader = Boolean(title || subtitle || rightSlot)
  return (
    <Tag id={id} className={cn("min-w-0", className)}>
      {hasHeader ? (
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
          <div className="min-w-0">
            {title ? (
              <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
                {title}
              </h2>
            ) : null}
            {subtitle ? <p className="mt-0.5 text-[12px] text-muted-foreground">{subtitle}</p> : null}
          </div>
          {rightSlot ? <div className="flex shrink-0 items-center gap-2">{rightSlot}</div> : null}
        </div>
      ) : null}
      {chrome === "plain" ? (
        <div className={cn(bodyClassName)}>{children}</div>
      ) : (
        <Card className="overflow-hidden border-border bg-surface-raised shadow-elev-1">
          <CardContent className={cn(bodyClassName)}>{children}</CardContent>
        </Card>
      )}
    </Tag>
  )
}
