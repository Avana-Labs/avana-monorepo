"use client"

import { useEffect, useRef, useState } from "react"
import { ChevronLeft, ChevronRight } from "@/app/components/icons"

const ARROW_CLASS =
  "inline-flex size-10 items-center justify-center rounded-full border border-border bg-muted text-foreground transition-colors hover:bg-hover disabled:pointer-events-none disabled:opacity-40"

export function CarouselArrowButtons({
  canPrev,
  canNext,
  onPrev,
  onNext,
  prevLabel = "Previous",
  nextLabel = "Next",
}: {
  canPrev: boolean
  canNext: boolean
  onPrev: () => void
  onNext: () => void
  prevLabel?: string
  nextLabel?: string
}) {
  return (
    <div className="flex items-center gap-2">
      <button type="button" aria-label={prevLabel} disabled={!canPrev} onClick={onPrev} className={ARROW_CLASS}>
        <ChevronLeft className="h-5 w-5" />
      </button>
      <button type="button" aria-label={nextLabel} disabled={!canNext} onClick={onNext} className={ARROW_CLASS}>
        <ChevronRight className="h-5 w-5" />
      </button>
    </div>
  )
}

// Snap can cancel `behavior: "smooth"` and jump; lift it for the animation, then restore.
// `generationRef` lets a newer scroll or drag cancel an older animation's restore.
function smoothScrollBy(scroller: HTMLDivElement, left: number, generationRef: { current: number }) {
  const generation = ++generationRef.current
  scroller.style.scrollSnapType = "none"
  scroller.scrollBy({ left, behavior: "smooth" })

  const restoreSnap = () => {
    if (generation !== generationRef.current) return
    scroller.style.scrollSnapType = ""
    scroller.removeEventListener("scrollend", restoreSnap)
  }
  scroller.addEventListener("scrollend", restoreSnap)
  window.setTimeout(restoreSnap, 550)
}

/** Pointer travel (px) before a mouse press becomes a drag, so clicks on cards still work. */
const DRAG_THRESHOLD_PX = 6

/**
 * Native horizontal scroller with arrow controls. Trackpad and touch swipes scroll it
 * natively; `dragToScroll` adds click-and-drag for a mouse, snapping to the nearest card
 * on release.
 */
export function useOverflowCarousel({ dragToScroll = false }: { dragToScroll?: boolean } = {}) {
  const scrollerRef = useRef<HTMLDivElement>(null)
  const scrollGenerationRef = useRef(0)
  const [canPrev, setCanPrev] = useState(false)
  const [canNext, setCanNext] = useState(true)

  const updateScrollState = () => {
    const scroller = scrollerRef.current
    if (!scroller) return
    const maxScroll = scroller.scrollWidth - scroller.clientWidth
    setCanPrev(scroller.scrollLeft > 4)
    setCanNext(maxScroll > 4 && scroller.scrollLeft < maxScroll - 4)
  }

  useEffect(() => {
    const scroller = scrollerRef.current
    if (!scroller) return
    updateScrollState()
    scroller.addEventListener("scroll", updateScrollState, { passive: true })
    const observer = new ResizeObserver(updateScrollState)
    observer.observe(scroller)
    return () => {
      scroller.removeEventListener("scroll", updateScrollState)
      observer.disconnect()
    }
  }, [])

  useEffect(() => {
    const scroller = scrollerRef.current
    if (!scroller || !dragToScroll) return

    let drag: { pointerId: number; startX: number; startScrollLeft: number; moved: boolean } | null = null
    let suppressClick = false

    const onPointerDown = (event: PointerEvent) => {
      if (event.pointerType !== "mouse" || event.button !== 0) return
      drag = { pointerId: event.pointerId, startX: event.clientX, startScrollLeft: scroller.scrollLeft, moved: false }
    }
    const onPointerMove = (event: PointerEvent) => {
      if (!drag || drag.pointerId !== event.pointerId) return
      const dx = event.clientX - drag.startX
      if (!drag.moved) {
        if (Math.abs(dx) < DRAG_THRESHOLD_PX) return
        drag.moved = true
        scrollGenerationRef.current += 1
        scroller.setPointerCapture?.(event.pointerId)
        // Snap and smooth scrolling would fight the pointer; lift them for the drag.
        scroller.style.scrollSnapType = "none"
        scroller.style.scrollBehavior = "auto"
        scroller.style.cursor = "grabbing"
        scroller.style.userSelect = "none"
      }
      scroller.scrollLeft = drag.startScrollLeft - dx
    }
    const onPointerEnd = (event: PointerEvent) => {
      if (!drag || drag.pointerId !== event.pointerId) return
      const moved = drag.moved
      drag = null
      if (!moved) return
      if (scroller.hasPointerCapture?.(event.pointerId)) scroller.releasePointerCapture(event.pointerId)
      scroller.style.scrollBehavior = ""
      scroller.style.cursor = ""
      scroller.style.userSelect = ""
      suppressClick = true
      // A cancelled pointer never fires a click; clear the flag so the next real click works.
      window.setTimeout(() => {
        suppressClick = false
      }, 0)

      // Settle on the card nearest the scroller's start edge, as the snap would.
      const padStart = Number.parseFloat(getComputedStyle(scroller).scrollPaddingLeft) || 0
      const edge = scroller.getBoundingClientRect().left + padStart
      const cards = Array.from(scroller.firstElementChild?.children ?? [])
      let offset = 0
      let best = Number.POSITIVE_INFINITY
      for (const card of cards) {
        const delta = card.getBoundingClientRect().left - edge
        if (Math.abs(delta) < best) {
          best = Math.abs(delta)
          offset = delta
        }
      }
      smoothScrollBy(scroller, offset, scrollGenerationRef)
    }
    const onClickCapture = (event: MouseEvent) => {
      if (!suppressClick) return
      suppressClick = false
      event.preventDefault()
      event.stopPropagation()
    }
    const onDragStart = (event: DragEvent) => event.preventDefault()

    scroller.addEventListener("pointerdown", onPointerDown)
    scroller.addEventListener("pointermove", onPointerMove)
    scroller.addEventListener("pointerup", onPointerEnd)
    scroller.addEventListener("pointercancel", onPointerEnd)
    scroller.addEventListener("click", onClickCapture, true)
    scroller.addEventListener("dragstart", onDragStart)
    return () => {
      scroller.removeEventListener("pointerdown", onPointerDown)
      scroller.removeEventListener("pointermove", onPointerMove)
      scroller.removeEventListener("pointerup", onPointerEnd)
      scroller.removeEventListener("pointercancel", onPointerEnd)
      scroller.removeEventListener("click", onClickCapture, true)
      scroller.removeEventListener("dragstart", onDragStart)
    }
  }, [dragToScroll])

  const scrollByCard = (direction: -1 | 1) => {
    const scroller = scrollerRef.current
    if (!scroller) return
    const card = scroller.querySelector("[data-carousel-card]") ?? scroller.querySelector(":scope > * > *")
    const distance = (card?.getBoundingClientRect().width ?? scroller.clientWidth / 3) + 12
    smoothScrollBy(scroller, direction * distance, scrollGenerationRef)
  }

  return { scrollerRef, canPrev, canNext, scrollByCard }
}
