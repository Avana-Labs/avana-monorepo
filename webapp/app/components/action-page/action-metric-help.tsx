"use client"

import { Info } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"

// useLayoutEffect warns during SSR; positioning only ever runs client-side after an open.
const useIsomorphicLayoutEffect = typeof window !== "undefined" ? useLayoutEffect : useEffect

type Coords = { top: number; left: number; placement: "top" | "bottom" }

export function ActionMetricHelp({ text, topic }: { text: string; topic?: string }) {
  const { t } = useTranslation()
  const ariaLabel = topic ? t("More information about {topic}").replace("{topic}", t(topic)) : t("More information")
  const [open, setOpen] = useState(false)
  const [pinned, setPinned] = useState(false)
  const rootRef = useRef<HTMLSpanElement | null>(null)
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const tooltipRef = useRef<HTMLSpanElement | null>(null)
  const tooltipId = useId()
  // The tooltip renders in a body portal so no ancestor's `overflow` (table scroll wrappers,
  // rounded cards) can clip it. Coordinates are measured from the trigger each time it opens.
  const [coords, setCoords] = useState<Coords | null>(null)

  useIsomorphicLayoutEffect(() => {
    if (!open) return
    const update = () => {
      const btn = buttonRef.current
      if (!btn) return
      const rect = btn.getBoundingClientRect()
      const tip = tooltipRef.current
      const tipH = tip?.offsetHeight ?? 40
      const tipW = tip?.offsetWidth ?? 256
      const gap = 8
      const margin = 8
      const placement: "top" | "bottom" = rect.top >= tipH + gap + margin ? "top" : "bottom"
      const top = placement === "top" ? rect.top - gap : rect.bottom + gap
      // Center on the trigger, then clamp so a right/left-edge (i) keeps the bubble on-screen.
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

    const close = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false)
        setPinned(false)
      }
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false)
        setPinned(false)
      }
    }

    document.addEventListener("pointerdown", close)
    document.addEventListener("keydown", closeOnEscape)
    return () => {
      document.removeEventListener("pointerdown", close)
      document.removeEventListener("keydown", closeOnEscape)
    }
  }, [open])

  return (
    <span
      ref={rootRef}
      className="relative inline-flex"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => {
        if (!pinned) setOpen(false)
      }}
    >
      <button
        ref={buttonRef}
        type="button"
        className="inline-flex size-4 items-center justify-center rounded-full text-muted-foreground/70 transition-colors hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        aria-label={ariaLabel}
        aria-describedby={open ? tooltipId : undefined}
        aria-expanded={open}
        onFocus={() => setOpen(true)}
        onBlur={() => {
          if (!pinned) setOpen(false)
        }}
        onClick={() => {
          setPinned((current) => {
            setOpen(!current)
            return !current
          })
        }}
      >
        <Info className="size-3.5" aria-hidden />
      </button>
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
              className="pointer-events-none z-[100] w-max max-w-64 rounded-radius-sm border border-border bg-background px-3 py-2 text-left text-xs font-normal leading-5 text-foreground shadow-elev-2"
            >
              {t(text)}
            </span>,
            document.body,
          )
        : null}
    </span>
  )
}
