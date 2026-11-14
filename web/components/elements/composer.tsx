"use client"

import { type ComponentProps } from "react"
import { cn } from "@/lib/utils"
import { floating, ghostButton, mono, paper } from "@/lib/surfaces"
import { clamp, pct } from "@/lib/range"

interface ComposerUsage {
  input: number
  output: number
  total: number
}

export function Composer({ className, ...props }: ComponentProps<"div">) {
  return <div data-slot="composer" className={cn("relative w-full max-w-lg", className)} {...props} />
}

export function ComposerBar({
  dragActive = false,
  className,
  ...props
}: ComponentProps<"div"> & { dragActive?: boolean }) {
  return (
    <div
      data-slot="composer-bar"
      data-drag-active={dragActive || undefined}
      className={cn(
        paper,
        "flex w-full flex-col gap-2 rounded-[24px] p-2.5 transition-colors",
        dragActive && "bg-blue-500/[0.04] dark:bg-blue-500/10",
        className,
      )}
      {...props}
    />
  )
}

export function ComposerToolbar({ className, ...props }: ComponentProps<"div">) {
  return <div data-slot="composer-toolbar" className={cn("flex items-center justify-between", className)} {...props} />
}

export function ComposerActions({ className, ...props }: ComponentProps<"div">) {
  return <div data-slot="composer-actions" className={cn("flex items-center gap-1.5", className)} {...props} />
}

export function ComposerContext({
  usage,
  className,
  ...props
}: Omit<ComponentProps<"div">, "children"> & { usage: ComposerUsage }) {
  const used = usage.input + usage.output
  const fraction = usage.total === 0 ? 0 : used / usage.total
  const warn = fraction > 0.85
  const circumference = 2 * Math.PI * 6
  const segments = [
    { label: "Input", value: usage.input, className: "bg-foreground/45" },
    { label: "Output", value: usage.output, className: "bg-foreground/80" },
  ]

  return (
    <div data-slot="composer-context" className={cn("group/ctx relative", className)} {...props}>
      <div
        className={cn(
          floating,
          "absolute end-0 bottom-full z-10 mb-2 flex w-60 origin-bottom-right flex-col gap-3.5 rounded-2xl p-4",
          "transition-[opacity,scale] duration-200 ease-[cubic-bezier(0.23,1,0.32,1)] motion-reduce:transition-none",
          "pointer-events-none scale-[0.97] opacity-0",
          "group-hover/ctx:pointer-events-auto group-hover/ctx:scale-100 group-hover/ctx:opacity-100",
          "group-focus-within/ctx:pointer-events-auto group-focus-within/ctx:scale-100 group-focus-within/ctx:opacity-100",
        )}
      >
        <div className="flex items-baseline justify-between">
          <p className="text-[14px] font-normal leading-5">Context</p>
          <p className={cn(mono, "tabular-nums", warn ? "text-red-500 dark:text-red-400" : "text-foreground/35")}>
            {Math.round(fraction * 100)}%
          </p>
        </div>
        <div className="bg-foreground/[0.06] flex h-[5px] w-full gap-px overflow-hidden rounded-full">
          {segments.map((segment) => (
            <span
              key={segment.label}
              className={cn("h-full transition-[width] duration-700 motion-reduce:transition-none", segment.className)}
              style={{ width: `${pct(segment.value, usage.total)}%` }}
            />
          ))}
        </div>
        <div className="flex flex-col gap-2">
          {segments.map((segment) => (
            <div key={segment.label} className="text-foreground/55 flex items-center gap-2.5 text-[13px]">
              <span aria-hidden className={cn("size-1.5 rounded-full", segment.className)} />
              <span className="flex-1">{segment.label}</span>
              <span className={cn(mono, "text-foreground/40 tabular-nums")}>{segment.value.toLocaleString()}</span>
            </div>
          ))}
        </div>
        <div className="bg-foreground/[0.06] h-px" />
        <div className="text-foreground/55 flex items-center justify-between text-[13px]">
          <span>Total</span>
          <span className={cn(mono, "text-foreground/40 tabular-nums")}>
            {used.toLocaleString()} / {usage.total.toLocaleString()}
          </span>
        </div>
      </div>
      <button
        type="button"
        aria-label="Context usage"
        className={cn(ghostButton, "size-8", warn && "text-red-500 dark:text-red-400")}
      >
        <svg viewBox="0 0 16 16" className="size-4 -rotate-90" aria-hidden>
          <circle cx="8" cy="8" r="6" fill="none" strokeWidth="2.5" className="stroke-foreground/10" />
          <circle
            cx="8"
            cy="8"
            r="6"
            fill="none"
            strokeWidth="2.5"
            strokeLinecap="round"
            className="stroke-current transition-[stroke-dashoffset] duration-700 motion-reduce:transition-none"
            strokeDasharray={circumference}
            strokeDashoffset={circumference * (1 - clamp(fraction, 0, 1))}
          />
        </svg>
      </button>
    </div>
  )
}
