"use client"

import { useCallback, useEffect, useRef, useState, type ReactNode } from "react"
import { ArrowUpRightLong, ChevronLeft, ChevronRight } from "@/app/components/icons"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TABLE_BASE, TABLE_COLUMN_PHONE_CLASS, TABLE_FIXED, type TableColumnLayout } from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"

export function DesktopTableSurface({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("overflow-hidden rounded-radius-xl bg-transparent", className)}>{children}</div>
}

export function SortIcon() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 12 16"
      fill="none"
      className="size-[14px] shrink-0 text-muted-foreground/70 dark:text-white/60"
    >
      <path d="M4 5 6 3l2 2" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M4 11 6 13l2-2" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

/**
 * Sortable column header label. Uppercases in CSS (`!uppercase`: Tailwind preflight resets
 * `text-transform` on buttons, so the `<th>`'s uppercase would not reach the label) and never
 * wraps, so every table's header strip reads the same. `hint` explains the column on hover.
 */
export function SortHeaderButton({
  label,
  active,
  onClick,
  hint,
}: {
  label: ReactNode
  active: boolean
  onClick: () => void
  hint?: string
}) {
  const button = (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex items-center gap-2 whitespace-nowrap !uppercase transition-colors",
        active ? "text-foreground dark:text-white" : "text-muted-foreground dark:text-white/42",
      )}
    >
      <span>{label}</span>
      <SortIcon />
    </button>
  )
  return hint ? <TableHeaderHint hint={hint}>{button}</TableHeaderHint> : button
}

const TABLE_SCROLL_ARROW_CLASS =
  "inline-flex size-6 items-center justify-center rounded-full text-foreground transition-colors hover:bg-hover disabled:pointer-events-none disabled:opacity-30 dark:text-white"

/**
 * Shared desktop table shell: a `table-fixed` table sized by `tableColumnLayout`. It fills its
 * container above `layout.minWidth`; below that the columns scroll horizontally under the
 * pinned identity column (`tableStickyCell`), and prev/next arrows appear in the header strip.
 */
export function ScrollableTable({
  layout,
  children,
  className,
}: {
  layout: TableColumnLayout
  children: ReactNode
  className?: string
}) {
  const { t } = useTranslation()
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const [scrollState, setScrollState] = useState({ canPrev: false, canNext: false })

  const measure = useCallback(() => {
    const scroller = scrollerRef.current
    if (!scroller) return
    const maxScroll = scroller.scrollWidth - scroller.clientWidth
    const next = { canPrev: scroller.scrollLeft > 1, canNext: scroller.scrollLeft < maxScroll - 1 }
    setScrollState((current) => (current.canPrev === next.canPrev && current.canNext === next.canNext ? current : next))
  }, [])

  useEffect(() => {
    const scroller = scrollerRef.current
    if (!scroller) return
    measure()
    scroller.addEventListener("scroll", measure, { passive: true })
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure)
    observer?.observe(scroller)
    return () => {
      scroller.removeEventListener("scroll", measure)
      observer?.disconnect()
    }
  }, [measure])

  const scrollByPage = (direction: 1 | -1) => {
    const scroller = scrollerRef.current
    if (!scroller) return
    // Page by the scrolled region (the viewport minus the pinned identity column).
    const pinned = scroller.querySelector<HTMLElement>("thead th.sticky")
    const step = Math.max(120, scroller.clientWidth - (pinned?.offsetWidth ?? 0) - 48)
    scroller.scrollBy({ left: direction * step, behavior: "smooth" })
  }

  const overflowing = scrollState.canPrev || scrollState.canNext

  return (
    // overflow-hidden: without it a phone's layout viewport widens to the table's scroll width
    // (the whole page then scrolls sideways) even though the inner scroller clips it.
    <div className="relative overflow-hidden">
      <div
        ref={scrollerRef}
        className="overflow-x-auto overscroll-x-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {/* Phones drop the desktop min width: the per-kind px columns set the scroll width there. */}
        <table
          className={cn(TABLE_FIXED, TABLE_BASE, "max-md:!min-w-0", className)}
          style={{ minWidth: layout.minWidth }}
        >
          <colgroup>
            {layout.widths.map((width, index) => (
              <col key={index} style={{ width }} className={TABLE_COLUMN_PHONE_CLASS[layout.kinds[index]]} />
            ))}
          </colgroup>
          {children}
        </table>
      </div>
      {scrollState.canNext ? (
        <div
          aria-hidden
          className="pointer-events-none absolute bottom-0 right-0 top-[33px] z-[2] w-12 bg-gradient-to-l from-background to-transparent"
        />
      ) : null}
      {overflowing ? (
        <div className="absolute right-0 top-0 z-[3] flex h-[33px] items-center gap-1 bg-table-header pl-1 pr-3 before:pointer-events-none before:absolute before:inset-y-0 before:right-full before:w-10 before:bg-gradient-to-l before:from-table-header before:to-transparent">
          <button
            type="button"
            aria-label={t("Scroll table left")}
            disabled={!scrollState.canPrev}
            onClick={() => scrollByPage(-1)}
            className={TABLE_SCROLL_ARROW_CLASS}
          >
            <ChevronLeft className="size-4" />
          </button>
          <button
            type="button"
            aria-label={t("Scroll table right")}
            disabled={!scrollState.canNext}
            onClick={() => scrollByPage(1)}
            className={TABLE_SCROLL_ARROW_CLASS}
          >
            <ChevronRight className="size-4" />
          </button>
        </div>
      ) : null}
    </div>
  )
}

export function SilentActionHeader({ className }: { className?: string }) {
  return <th className={cn("rounded-r-radius-lg bg-table-header px-4 pb-2 pt-2.5 pr-4", className)} />
}

export function HoverActionGroup({
  children,
  className,
  align = "end",
}: {
  children: ReactNode
  className?: string
  align?: "start" | "end"
}) {
  // Always visible on desktop, but faded at rest (both chips share the muted
  // fill) so the row stays calm; hovering (or keyboard focus) fades them to full
  // opacity while the primary chip morphs to the brand fill.
  return (
    <div
      className={cn(
        // Touch screens have no hover, so the pills stay at full strength there.
        "flex gap-1.5 opacity-60 transition-opacity duration-200 ease-out group-hover:opacity-100 group-focus-within:opacity-100 [@media(hover:none)]:opacity-100",
        align === "start" ? "justify-start" : "justify-end",
        className,
      )}
    >
      {children}
    </div>
  )
}

/**
 * Shared classes for the bare "open this row" affordance at the end of a desktop
 * table row: a long diagonal arrow that rests muted and sharpens to full
 * contrast on row hover or keyboard focus (same read as the borrow detail
 * tables). Replaces the round chevron chip, which looked like a control rather
 * than a pointer to the detail page the whole row already opens.
 */
export const ROW_OPEN_ARROW_CLASS =
  "inline-flex size-9 items-center justify-center rounded-full text-muted-foreground/60 transition-colors duration-200 ease-out hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background group-hover:text-foreground group-focus-within:text-foreground"

/**
 * The arrow itself. Rendered well above the 14px table-icon default: hugeicons
 * draws the diagonal inside the middle ~13 units of its 24-unit box, so the
 * glyph has to be sized up before the shaft reads as long rather than stubby.
 */
export function RowOpenArrowIcon({ className }: { className?: string }) {
  return <ArrowUpRightLong className={cn("!size-[26px]", className)} strokeWidth={1.5} aria-hidden />
}
