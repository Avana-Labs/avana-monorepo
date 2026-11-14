"use client"

import { useLayoutEffect, useRef } from "react"
import { cn } from "@/lib/utils"

const SKELETON_SHIMMER_DURATION_MS = 1600

interface SkeletonProps extends React.HTMLAttributes<HTMLDivElement> {
  /**
   * Deprecated / no-op: the directional "moving train" shimmer is now the default
   * for every skeleton. Kept so existing callers that pass `shimmer` still type-check.
   */
  shimmer?: boolean
}

/**
 * Skeleton placeholder. A muted base with a bright band that sweeps left → right on
 * a loop — a directional shimmer, not an opacity fade. The global
 * `.skeleton-shimmer` class owns the loop so it cannot disappear when Tailwind
 * regenerates arbitrary utilities during development.
 *
 * Decorative by default (`aria-hidden`): a single loading region announces "Loading"
 * once, rather than a screen reader crawling over dozens of placeholder blocks. Pass
 * `aria-hidden={false}` to opt a specific placeholder back in.
 */
function Skeleton({ className, shimmer: _shimmer, ...props }: SkeletonProps) {
  const ref = useRef<HTMLDivElement>(null)

  useLayoutEffect(() => {
    const element = ref.current
    if (!element || typeof element.animate !== "function") return
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    // Start every instance at the document timeline's current phase. When a
    // provider replaces an identical loading tree, the new skeleton continues
    // the existing sweep instead of restarting from the left edge.
    const timelineTime = Number(document.timeline.currentTime ?? 0)
    const animation = element.animate([{ backgroundPosition: "-125% 0" }, { backgroundPosition: "225% 0" }], {
      duration: SKELETON_SHIMMER_DURATION_MS,
      delay: -(timelineTime % SKELETON_SHIMMER_DURATION_MS),
      easing: "linear",
      iterations: Infinity,
    })

    return () => animation.cancel()
  }, [])

  return <div ref={ref} aria-hidden="true" className={cn("skeleton-shimmer rounded-md", className)} {...props} />
}

export { Skeleton }
