"use client"

import { useEffect, useRef, useState } from "react"
import { Popover as PopoverPrimitive } from "radix-ui"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  FACET_TITLES,
  PILL_BASE,
  PILL_OPEN,
  PillClearButton,
  pillTriggerClass,
  showsClear,
  useClearFacetLabel,
  type FacetPopoverProps,
} from "@/app/lib/ui/market-filter-pill"

// Loaded lazily by `market-filters.tsx` after mount, so Radix Popover (~19 KiB gzip) stays out of
// the Lend / Borrow / Multiply first load; `StaticFacetPill` renders the closed pill until then.

const PANEL_CLASS =
  "z-[60] flex w-[min(var(--panel-width),calc(100vw-24px))] data-[fit=content]:w-max data-[fit=content]:min-w-[216px] data-[fit=content]:max-w-[min(var(--panel-width),calc(100vw-24px))] flex-col overflow-hidden rounded-[14px] border border-border bg-popover text-popover-foreground shadow-elev-2 outline-none " +
  "max-h-[min(380px,var(--radix-popover-content-available-height))] dark:border-white/[0.08] dark:bg-[#1c1c1c] " +
  "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-98 data-[state=open]:zoom-in-98 data-[side=bottom]:slide-in-from-top-1"

/** Height of the sticky site header the pills scroll under. */
const SITE_HEADER_PX = 64

/** Tallest a panel gets (matches the `max-h` in PANEL_CLASS). */
const PANEL_MAX_PX = 380
/** Search row + section header + list padding + borders; each option row is 36px. */
const PANEL_CHROME_PX = 80
const ROW_PX = 36

function panelHeightFor(rowCount: number) {
  return Math.min(PANEL_MAX_PX, PANEL_CHROME_PX + rowCount * ROW_PX)
}

/**
 * Scrolls the page only as far as needed for THIS panel to open fully below its pill (the pill's
 * 8px offset + a 12px gutter included); a panel that already fits never moves the page.
 */
function scrollRoomBelow(anchor: HTMLElement | null, panelHeight: number) {
  if (!anchor || typeof window === "undefined") return
  const rect = anchor.getBoundingClientRect()
  const shortfall = rect.bottom + 8 + panelHeight + 12 - window.innerHeight
  if (shortfall <= 0) return
  // Never scroll the pill itself under the sticky site header + a little air.
  const delta = Math.min(shortfall, Math.max(0, rect.top - SITE_HEADER_PX - 24))
  if (delta > 0) window.scrollBy({ top: delta, behavior: "smooth" })
}

/** On the phone rail, scroll a partly hidden pill fully into view before its panel anchors to it. */
function revealInRail(anchor: HTMLElement | null) {
  const rail = anchor?.parentElement
  if (!anchor || !rail || rail.scrollWidth <= rail.clientWidth) return
  const pill = anchor.getBoundingClientRect()
  const box = rail.getBoundingClientRect()
  const inset = 12
  if (pill.left < box.left + inset) rail.scrollLeft -= box.left + inset - pill.left
  else if (pill.right > box.right - inset) rail.scrollLeft += pill.right - (box.right - inset)
}

/** Offset from the pill's left edge that keeps a `panelWidth` panel inside a 12px viewport gutter. */
function horizontalOffset(anchor: HTMLElement | null, panelWidth: number) {
  if (!anchor || typeof window === "undefined") return 0
  const gutter = 12
  const width = Math.min(panelWidth, window.innerWidth - gutter * 2)
  const left = anchor.getBoundingClientRect().left
  const clamped = Math.min(Math.max(left, gutter), window.innerWidth - gutter - width)
  return Math.round(clamped - left)
}

export default function FacetPopover({
  facet,
  trigger,
  panelWidth,
  fitContent = false,
  rowCount,
  onClearFacet,
  selectedCount,
  children,
  initialOpen = false,
}: FacetPopoverProps) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(initialOpen)
  const inputRef = useRef<HTMLInputElement | null>(null)
  const anchorRef = useRef<HTMLSpanElement | null>(null)
  const [alignOffset, setAlignOffset] = useState(0)
  // Radix mounts the portaled panel a render after `open` flips, so measure it when its node
  // attaches: clamp it inside the viewport gutter using its REAL width (content-sized panels are
  // narrower than their max), which keeps it under its pill.
  // An inline ref runs again on every re-render (each option toggle), so position and scroll only
  // on the first attach of each opening — toggling an option must never move the page.
  const measuredRef = useRef(false)
  const measurePanel = (node: HTMLDivElement | null) => {
    if (!node?.offsetWidth || measuredRef.current) return
    measuredRef.current = true
    setAlignOffset(horizontalOffset(anchorRef.current, node.offsetWidth))
    // Make room below only once the panel exists: a smooth scroll started during the click is
    // cancelled by the mount, which left the panel open short for a beat.
    scrollRoomBelow(anchorRef.current, panelHeightFor(rowCount))
  }

  // Close once the pill scrolls under the sticky site header (or off-screen), so the panel never
  // floats detached over the header.
  useEffect(() => {
    if (!open) return
    const closeWhenHidden = () => {
      const rect = anchorRef.current?.getBoundingClientRect()
      if (rect && (rect.bottom < SITE_HEADER_PX || rect.top > window.innerHeight)) setOpen(false)
    }
    window.addEventListener("scroll", closeWhenHidden, { passive: true })
    return () => window.removeEventListener("scroll", closeWhenHidden)
  }, [open])
  const clearLabel = useClearFacetLabel(facet)

  return (
    <PopoverPrimitive.Root
      open={open}
      onOpenChange={(next) => {
        if (next) {
          measuredRef.current = false
          revealInRail(anchorRef.current)
          setAlignOffset(horizontalOffset(anchorRef.current, panelWidth))
        }
        setOpen(next)
      }}
    >
      <PopoverPrimitive.Anchor asChild>
        <span
          ref={anchorRef}
          className={cn(PILL_BASE, open && PILL_OPEN)}
          data-facet={facet}
          data-state={open ? "open" : "closed"}
        >
          <PopoverPrimitive.Trigger className={pillTriggerClass(facet, selectedCount)}>
            {trigger(open)}
          </PopoverPrimitive.Trigger>
          {showsClear(facet, selectedCount) ? <PillClearButton label={clearLabel} onClick={onClearFacet} /> : null}
        </span>
      </PopoverPrimitive.Anchor>
      <PopoverPrimitive.Portal>
        <PopoverPrimitive.Content
          ref={measurePanel}
          side="bottom"
          align="start"
          sideOffset={8}
          // Always drop DOWN (no flip above the pill); the horizontal offset is computed on open
          // so a pill near the right edge (phones) still opens fully on-screen.
          avoidCollisions={false}
          alignOffset={alignOffset}
          collisionPadding={12}
          aria-label={t(FACET_TITLES[facet])}
          className={PANEL_CLASS}
          data-fit={fitContent ? "content" : undefined}
          style={{ ["--panel-width" as string]: `${panelWidth}px` }}
          onOpenAutoFocus={(event) => {
            // Touch screens would pop the keyboard over the list; keep focus on the panel there.
            event.preventDefault()
            if (typeof window !== "undefined" && window.matchMedia?.("(hover: hover)").matches) {
              inputRef.current?.focus()
            }
          }}
        >
          {children(inputRef)}
        </PopoverPrimitive.Content>
      </PopoverPrimitive.Portal>
    </PopoverPrimitive.Root>
  )
}
