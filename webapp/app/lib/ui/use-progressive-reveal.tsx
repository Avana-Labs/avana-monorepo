"use client"

import * as React from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type UseProgressiveRevealOptions = {
  /** Total number of items available to reveal. */
  total: number
  /** How many extra items each scroll reveal adds. Defaults to 12. */
  chunkSize?: number
  /** Initial number of items shown on first paint. Defaults to `chunkSize`. */
  initialCount?: number
  /** Brief pause before the next chunk appears, so the reveal reads as a load. */
  revealDelayMs?: number
  /** How far ahead of the viewport the sentinel arms the next reveal. */
  rootMargin?: string
  /**
   * When this value changes the reveal resets to `initialCount` — pass the
   * active filter/search/tab state so switching filters starts from the top.
   */
  resetKey?: unknown
}

type ProgressiveReveal = {
  /** Number of items to render — slice your list to `list.slice(0, visibleCount)`. */
  visibleCount: number
  /** True while more items remain hidden below the fold. */
  hasMore: boolean
  /** True during the brief loading pause between reveals. */
  isRevealing: boolean
  /** Attach to the sentinel element rendered after the last visible item. */
  sentinelRef: React.RefObject<HTMLDivElement>
}

/**
 * Reveal-on-scroll in place of pagination. Only the first `initialCount` items
 * render up front; an off-screen sentinel then arms the next chunk as the user
 * scrolls, with a short loading pause so content eases in rather than dumping
 * the whole list at once. Data is expected to already be in memory — this only
 * controls how much of it is rendered.
 */
export function useProgressiveReveal({
  total,
  chunkSize = 12,
  initialCount,
  revealDelayMs = 350,
  rootMargin = "200px 0px",
  resetKey,
}: UseProgressiveRevealOptions): ProgressiveReveal {
  const base = Math.max(1, initialCount ?? chunkSize)
  const [visibleCount, setVisibleCount] = React.useState(base)
  const [isRevealing, setIsRevealing] = React.useState(false)
  const sentinelRef = React.useRef<HTMLDivElement>(null)

  // Restart from the top whenever the underlying filter/search changes.
  React.useEffect(() => {
    setVisibleCount(base)
    setIsRevealing(false)
  }, [resetKey, base])

  const hasMore = visibleCount < total

  // Watch the sentinel; entering the viewport begins the loading pause.
  React.useEffect(() => {
    if (!hasMore) return
    const element = sentinelRef.current
    if (!element) return

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setIsRevealing(true)
        }
      },
      { rootMargin },
    )

    observer.observe(element)
    return () => observer.disconnect()
  }, [hasMore, rootMargin, visibleCount])

  // After the pause, reveal the next chunk.
  React.useEffect(() => {
    if (!isRevealing) return
    const timer = setTimeout(() => {
      setVisibleCount((current) => Math.min(total, current + chunkSize))
      setIsRevealing(false)
    }, revealDelayMs)
    return () => clearTimeout(timer)
  }, [isRevealing, chunkSize, total, revealDelayMs])

  return { visibleCount, hasMore, isRevealing, sentinelRef }
}

/**
 * Sentinel + loading affordance rendered after the last visible item. Mounting
 * it near the bottom is what arms the next reveal; the spinner only shows during
 * the brief loading pause so the list stays quiet once fully revealed.
 */
export function RevealSentinel({
  sentinelRef,
  active,
  className,
}: {
  sentinelRef: React.RefObject<HTMLDivElement>
  active: boolean
  className?: string
}) {
  const { t } = useTranslation()
  return (
    <div ref={sentinelRef} aria-hidden={!active} className={className ?? "flex items-center justify-center py-8"}>
      {active ? (
        <span className="flex items-center gap-2 text-[13px] text-muted-foreground">
          <span className="size-4 animate-spin rounded-full border-2 border-border border-t-foreground/70" />
          {t("Loading more")}
        </span>
      ) : null}
    </div>
  )
}
