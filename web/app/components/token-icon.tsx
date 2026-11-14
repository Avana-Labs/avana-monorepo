"use client"

import Image from "next/image"
import { useState } from "react"
import { cn } from "@/lib/utils"
import { getTokenIconMeta, type TokenIconMeta } from "@/app/lib/token-icons"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

import { TOKEN_ICON_TABLE_PX, type TokenIconTableSize } from "@/app/lib/token-icon-sizes"

type TokenIconSize = "xs" | "sm" | "md" | TokenIconTableSize | "lg" | "xl"

const DIMENSIONS: Record<TokenIconSize, { box: string; text: string; px: number }> = {
  xs: { box: "h-4 w-4", text: "text-[7px]", px: 16 },
  sm: { box: "h-6 w-6", text: "text-[9px]", px: 24 },
  md: { box: "h-8 w-8", text: "text-[10px]", px: 32 },
  table: { box: "h-12 w-12", text: "text-[12px]", px: TOKEN_ICON_TABLE_PX },
  lg: { box: "h-12 w-12", text: "text-[12px]", px: TOKEN_ICON_TABLE_PX },
  xl: { box: "h-11 w-11", text: "text-[12px]", px: 44 },
}

export function TokenIcon({
  symbol,
  size = "md",
  className,
  ring = false,
  meta: metaOverride,
  eager = false,
  pixelSize,
}: {
  symbol: string
  size?: TokenIconSize
  className?: string
  ring?: boolean
  meta?: TokenIconMeta
  eager?: boolean
  /** Overrides the preset size box and image resolution (paired-loop layouts). */
  pixelSize?: number
}) {
  const meta = metaOverride ?? getTokenIconMeta(symbol)
  const { box, text, px: presetPx } = DIMENSIONS[size]
  const px = pixelSize ?? presetPx
  const [failed, setFailed] = useState(false)
  const showIcon = Boolean(meta.iconUrl) && !failed
  const fallbackLabel = meta.symbol[0]?.toUpperCase() ?? "?"

  return (
    <span
      className={cn(
        "relative inline-flex shrink-0 items-center justify-center font-semibold",
        pixelSize == null ? box : null,
        // A real token icon renders as a bare transparent PNG — no circular plate, card
        // background, ring or clip. Only the letter fallback keeps the colored avatar circle.
        showIcon
          ? null
          : cn("overflow-hidden rounded-full", ring && "ring-2 ring-background", meta.bgClass, meta.textClass, text),
        className,
      )}
      style={pixelSize == null ? undefined : { width: pixelSize, height: pixelSize }}
    >
      {showIcon ? (
        <Image
          src={sizedLocalIconSrc(meta.iconUrl as string, px)}
          alt={meta.symbol}
          width={px}
          height={px}
          sizes={`${px}px`}
          className="h-full w-full object-contain"
          loading={eager ? "eager" : "lazy"}
          fetchPriority={eager ? "high" : undefined}
          onError={() => setFailed(true)}
          unoptimized
        />
      ) : (
        fallbackLabel
      )}
    </span>
  )
}
