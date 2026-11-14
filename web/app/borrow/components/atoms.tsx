"use client"

import { memo, useState, type ButtonHTMLAttributes } from "react"
import Image from "next/image"
import { EnhancedGraph } from "@/app/components/enhanced-graph"
import type { BorrowAssetVisual } from "@/app/lib/data/borrow-domain"
import { TOKEN_ICON_TABLE_PX } from "@/app/lib/token-icon-sizes"
import { cn } from "@/lib/utils"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type TokenBubbleSize = "xs" | "sm" | "md" | "table" | "lg" | "xl"

const BUBBLE_DIMENSIONS: Record<TokenBubbleSize, { box: string; text: string; px: number }> = {
  xs: { box: "size-4", text: "text-[7px]", px: 16 },
  sm: { box: "size-5", text: "text-[8px]", px: 20 },
  md: { box: "size-7", text: "text-[9px]", px: 28 },
  table: { box: "size-12", text: "text-[12px]", px: TOKEN_ICON_TABLE_PX },
  lg: { box: "size-9", text: "text-[10px]", px: 36 },
  xl: { box: "size-11", text: "text-[11px]", px: 44 },
}

export function TokenBubble({
  visual,
  size = "sm",
  className,
  ring = true,
  eager = false,
}: {
  visual: BorrowAssetVisual
  size?: TokenBubbleSize
  className?: string
  ring?: boolean
  eager?: boolean
}) {
  const { box, text, px } = BUBBLE_DIMENSIONS[size]
  const [imgFailed, setImgFailed] = useState(false)
  const showIcon = Boolean(visual.iconUrl) && !imgFailed
  // Stock icons are edge-to-edge while coin PNGs carry ~9% transparent margin, so an
  // unscaled stock icon reads ~10% larger beside them — inset it to match.
  const isStockIcon = typeof visual.iconUrl === "string" && visual.iconUrl.includes("/stock-Icons/")

  return (
    <span
      className={cn(
        "relative inline-flex shrink-0 items-center justify-center font-medium",
        box,
        // A real token icon renders bare — no plate, background, ring or clip.
        // Only the initials fallback keeps the colored avatar circle.
        showIcon
          ? null
          : cn(
              "overflow-hidden rounded-full",
              ring && "ring-2 ring-background",
              visual.bgClass,
              visual.textClass,
              text,
            ),
        className,
      )}
    >
      {showIcon ? (
        <Image
          src={sizedLocalIconSrc(visual.iconUrl as string, px)}
          alt={visual.symbol}
          width={px}
          height={px}
          className={cn("h-full w-full object-contain", isStockIcon && "scale-[0.91]")}
          // Lazy-load + async-decode so a long market list doesn't decode every
          // off-screen icon up front.
          loading={eager ? "eager" : "lazy"}
          fetchPriority={eager ? "high" : undefined}
          decoding="async"
          onError={() => setImgFailed(true)}
          unoptimized
        />
      ) : (
        visual.shortLabel
      )}
    </span>
  )
}

export function TokenPairCell({
  visuals,
  name,
  subtitle,
  size = "sm",
  subtitleTruncate = true,
}: {
  visuals: [BorrowAssetVisual, BorrowAssetVisual]
  name: string
  subtitle?: string
  size?: "sm" | "md" | "lg"
  /** Truncate the subtitle to a single line with an ellipsis. Off = let short labels show in full. */
  subtitleTruncate?: boolean
}) {
  const bubbleSize: TokenBubbleSize = size === "lg" ? "xl" : size === "md" ? "table" : "sm"
  const offset = size === "lg" ? "-ml-3" : size === "md" ? "-ml-2.5" : "-ml-2"
  const nameCls =
    size === "lg"
      ? "text-[15px] font-normal tracking-normal"
      : size === "md"
        ? "text-[15px] font-normal tracking-normal"
        : "text-[13px] font-medium"
  const subtitleCls = size === "lg" ? "text-[12px]" : "text-[13px] font-normal tracking-normal"
  return (
    <div className="flex min-w-0 items-center gap-3">
      <div className="flex shrink-0 items-center">
        <TokenBubble visual={visuals[0]} size={bubbleSize} />
        <TokenBubble visual={visuals[1]} size={bubbleSize} className={offset} />
      </div>
      <div className="min-w-0">
        {/* One line: a pair name wrapping to two lines breaks the table's 72px row rhythm. */}
        <div className={cn("truncate leading-tight text-foreground dark:text-white", nameCls)}>{name}</div>
        {subtitle ? (
          <div className={cn("mt-0.5 text-muted-foreground", subtitleTruncate && "truncate", subtitleCls)}>
            {subtitle}
          </div>
        ) : null}
      </div>
    </div>
  )
}

export function TokenSingleCell({
  visual,
  name,
  subtitle,
  size = "md",
  eager = false,
}: {
  visual: BorrowAssetVisual
  name: string
  subtitle?: string
  size?: "sm" | "md" | "lg"
  eager?: boolean
}) {
  const bubbleSize: TokenBubbleSize = size === "lg" ? "xl" : size === "md" ? "table" : "sm"
  const nameCls = size === "lg" ? "text-[15px]" : "text-[14px]"
  const subtitleCls = size === "lg" ? "text-[12px]" : "text-xs"
  return (
    <div className="flex items-center gap-3">
      <TokenBubble visual={visual} size={bubbleSize} eager={eager} />
      <div className="min-w-0">
        <div className={cn("font-medium leading-tight text-foreground", nameCls)}>{name}</div>
        {subtitle ? <div className={cn("mt-0.5 truncate text-muted-foreground", subtitleCls)}>{subtitle}</div> : null}
      </div>
    </div>
  )
}

export const TrendSpark = memo(function TrendSpark({
  isPositive,
  seed,
  values,
  width = 64,
  height = 24,
}: {
  isPositive: boolean
  seed: string
  values?: number[]
  width?: number
  height?: number
}) {
  return (
    <div style={{ width, height }} className="shrink-0">
      <EnhancedGraph isPositive={isPositive} seed={seed} values={values} points={14} height={height} />
    </div>
  )
})

export function HfNumber({
  value,
  tone,
  size = "md",
}: {
  value: string
  tone: string
  size?: "sm" | "md" | "lg" | "table"
}) {
  const textSize =
    size === "lg" ? "text-[20px]" : size === "sm" ? "text-[11px]" : size === "table" ? "text-[15px]" : "text-[13px]"
  const weight = size === "table" ? "font-normal" : "font-medium"
  return <span className={cn("font-data tabular-nums", weight, textSize, tone)}>{value}</span>
}

type PillVariant = "primary" | "ghost" | "danger" | "success"

export function PillButton({
  variant = "primary",
  size = "sm",
  className,
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: PillVariant; size?: "sm" | "md" }) {
  const base =
    "inline-flex items-center justify-center rounded-radius-sm font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
  const sizeCls = size === "md" ? "h-9 px-4 text-[13px]" : "h-7 px-2.5 text-[12px]"
  const variantCls = {
    primary:
      "bg-brand text-white shadow-elev-1 hover:bg-brand/90 active:bg-brand/80 disabled:!opacity-100 disabled:bg-brand-soft disabled:text-brand-soft-foreground disabled:shadow-none",
    ghost: "border border-border bg-surface-raised text-foreground hover:bg-surface-hover",
    danger: "border border-destructive/30 bg-transparent text-destructive hover:bg-destructive/5 dark:text-rose-300",
    success: "bg-emerald-600 text-white hover:bg-emerald-700 disabled:bg-muted disabled:text-muted-foreground",
  }[variant]
  return (
    <button type="button" {...props} className={cn(base, sizeCls, variantCls, className)}>
      {children}
    </button>
  )
}
