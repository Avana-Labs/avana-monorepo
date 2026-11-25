"use client"

import { Children, Fragment } from "react"
import { ArrowDown } from "@/app/components/icons"
import {
  ACTION_FIELD_STACK_CLASS,
  ACTION_FIELD_SURFACE_CLASS,
} from "@/app/components/action-page/action-surface-tokens"
import { cn } from "@/lib/utils"
import type { ComponentPropsWithoutRef, ReactNode } from "react"

export function SwapStyleField({
  label,
  children,
  tone = "raised",
  className,
  ...props
}: {
  label: string
  children: React.ReactNode
  tone?: "raised" | "inset"
  className?: string
} & ComponentPropsWithoutRef<"div">) {
  return (
    <div
      className={cn(
        ACTION_FIELD_SURFACE_CLASS,
        "transition-[border-color,box-shadow] duration-200",
        tone === "raised" &&
          "border border-border bg-field-top text-card-foreground shadow-[0_1px_0_rgba(255,255,255,0.04)_inset] focus-within:border-brand/35 focus-within:shadow-[0_0_0_1px_hsl(var(--brand)/0.18),0_12px_32px_-20px_hsl(var(--brand)/0.22)] dark:shadow-none",
        tone === "inset" &&
          "border border-transparent bg-field-bottom focus-within:border-brand/30 focus-within:shadow-[0_0_0_1px_hsl(var(--brand)/0.12),0_8px_24px_-18px_hsl(var(--brand)/0.16)]",
        className,
      )}
      data-testid="swap-style-field"
      data-tone={tone}
      {...props}
    >
      {/* Press feedback lives on the INNER content only, so a click bounces the
          label/amount — never the card surface or its border. The back-out timing
          function overshoots on release for a noticeable spring. Suppressed while an
          interactive control (the asset pill, the Max/Balance button) is pressed:
          scaling the wrapper would shift that control out from under the cursor
          mid-press and drop the click. */}
      <div
        className="origin-center transition-transform duration-200 motion-safe:active:scale-[0.96] [&:has(:is(button,a):active)]:!scale-100"
        style={{ transitionTimingFunction: "cubic-bezier(0.34, 1.56, 0.64, 1)" }}
      >
        <div className="text-[15px] font-normal leading-5 text-foreground/70">{label}</div>
        {children}
      </div>
    </div>
  )
}

export function SwapStyleFieldStack({
  children,
  className,
  showConnector = true,
}: {
  children: ReactNode
  className?: string
  showConnector?: boolean
}) {
  const items = Children.toArray(children)
  return (
    <div className={cn(ACTION_FIELD_STACK_CLASS, className)} data-testid="swap-style-field-stack">
      {items.map((child, index) => (
        <Fragment key={index}>
          {child}
          {showConnector && index === 0 && items.length > 1 ? (
            // Uniswap-style directional affordance between the two fields. Decorative
            // only (not a swap button): borrow's collateral→borrow flow isn't
            // reversible, so this indicates direction without implying a toggle.
            <div aria-hidden className="relative z-10 -my-3 flex justify-center">
              <span className="flex size-7 items-center justify-center rounded-radius-md border-4 border-background bg-field-bottom text-muted-foreground">
                <ArrowDown className="size-3.5" />
              </span>
            </div>
          ) : null}
        </Fragment>
      ))}
    </div>
  )
}
