"use client"

import Image from "next/image"
import { useState } from "react"
import { getTokenIconMeta } from "@/app/lib/token-icons"
import { TOKEN_ICON_TABLE_PX } from "@/app/lib/token-icon-sizes"
import { cn } from "@/lib/utils"
import type { HomeAssetVisual } from "@/app/lib/home-view-model"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type TokenBubbleProps = {
  visual: HomeAssetVisual
  className?: string
}

type PairVisualProps = {
  visuals: [HomeAssetVisual, HomeAssetVisual]
  className?: string
}

export function TokenBubble({ visual, className }: TokenBubbleProps) {
  const meta = getTokenIconMeta(visual.symbol)
  const [imgFailed, setImgFailed] = useState(false)
  const showIcon = Boolean(meta.iconUrl) && !imgFailed

  return (
    <span
      className={cn(
        "inline-flex size-10 shrink-0 items-center justify-center font-data text-[11px] font-medium",
        showIcon ? undefined : cn("overflow-hidden rounded-full", visual.bgClassName, visual.textClassName),
        className,
      )}
      aria-hidden
    >
      {showIcon ? (
        <Image
          src={sizedLocalIconSrc(meta.iconUrl as string, TOKEN_ICON_TABLE_PX)}
          alt={visual.symbol}
          width={TOKEN_ICON_TABLE_PX}
          height={TOKEN_ICON_TABLE_PX}
          sizes={`${TOKEN_ICON_TABLE_PX}px`}
          className="h-full w-full object-contain"
          onError={() => setImgFailed(true)}
          unoptimized
        />
      ) : (
        visual.shortLabel
      )}
    </span>
  )
}

export function PairVisual({ visuals, className }: PairVisualProps) {
  return (
    <div className={cn("relative h-10 w-[3.25rem] shrink-0", className)} aria-hidden>
      <TokenBubble visual={visuals[0]} className="absolute left-0 top-0" />
      <TokenBubble visual={visuals[1]} className="absolute left-5 top-0" />
    </div>
  )
}
