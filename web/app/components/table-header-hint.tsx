"use client"

import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactNode } from "react"
import { createPortal } from "react-dom"
import { cn } from "@/lib/utils"

// useLayoutEffect warns during SSR; positioning only ever runs client-side after an open.
const useIsomorphicLayoutEffect = typeof window !== "undefined" ? useLayoutEffect : useEffect

type Coords = { top: number; left: number; placement: "top" | "bottom" }

/**
 * Desktop table header label that explains itself on hover: no (i) icon, the whole label is
 * the trigger. Mouse only (touch taps would fight the sort buttons), plus keyboard focus for
 * sortable headers. The bubble portals to body so table scroll wrappers can't clip it.
 */
export function TableHeaderHint({
  hint,
  children,
  className,
}: {
  /** Already-translated explanation. */
  hint: string
  children: ReactNode
  className?: string
}) {
  const [open, setOpen] = useState(false)
  const [coords, setCoords] = useState<Coords | null>(null)
  const triggerRef = useRef<HTMLSpanElement | null>(null)
  const tooltipRef = useRef<HTMLSpanElement | null>(null)
  const tooltipId = useId()

  useIsomorphicLayoutEffect(() => {
    if (!open) return
    const update = () => {
      const trigger = triggerRef.current
      if (!trigger) return
      const rect = trigger.getBoundingClientRect()
      const tipH = tooltipRef.current?.offsetHeight ?? 48
      const tipW = tooltipRef.current?.offsetWidth ?? 288
      const gap = 10
      const margin = 8
      const placement: "top" | "bottom" = rect.top >= tipH + gap + margin ? "top" : "bottom"
      const top = placement === "top" ? rect.top - gap : rect.bottom + gap
      const centered = rect.left + rect.width / 2
      const left = Math.min(Math.max(centered, tipW / 2 + margin), window.innerWidth - tipW / 2 - margin)
      setCoords({ top, left, placement })
    }
    update()
    window.addEventListener("scroll", update, true)
    window.addEventListener("resize", update)
    return () => {
      window.removeEventListener("scroll", update, true)
      window.removeEventListener("resize", update)
    }
  }, [open])

  useEffect(() => {
    if (!open) return
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false)
    }
    document.addEventListener("keydown", closeOnEscape)
    return () => document.removeEventListener("keydown", closeOnEscape)
  }, [open])

  return (
    <span
      ref={triggerRef}
      className={cn("inline-flex cursor-default", className)}
      aria-describedby={open ? tooltipId : undefined}
      onPointerEnter={(event) => {
        if (event.pointerType === "mouse") setOpen(true)
      }}
      onPointerLeave={() => setOpen(false)}
      onFocus={(event) => {
        if (event.target.matches(":focus-visible")) setOpen(true)
      }}
      onBlur={() => setOpen(false)}
    >
      {children}
      {open && typeof document !== "undefined"
        ? createPortal(
            <span
              ref={tooltipRef}
              id={tooltipId}
              role="tooltip"
              style={{
                position: "fixed",
                top: coords?.top ?? -9999,
                left: coords?.left ?? -9999,
                transform: `translate(-50%, ${coords?.placement === "bottom" ? "0" : "-100%"})`,
                visibility: coords ? "visible" : "hidden",
              }}
              className="pointer-events-none z-[100] w-max max-w-72 rounded-radius-md border border-border bg-popover px-4 py-2.5 text-center text-[13px] font-normal normal-case leading-5 tracking-normal text-popover-foreground shadow-elev-2"
            >
              {hint}
            </span>,
            document.body,
          )
        : null}
    </span>
  )
}
