import { cleanup, fireEvent, render } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useOverflowCarousel } from "@/app/components/carousel-arrow-buttons"

function Scroller({ dragToScroll, onCardClick }: { dragToScroll?: boolean; onCardClick: () => void }) {
  const { scrollerRef } = useOverflowCarousel({ dragToScroll })
  return (
    <div ref={scrollerRef} data-testid="scroller">
      <div>
        <button onClick={onCardClick}>Card A</button>
        <button onClick={onCardClick}>Card B</button>
      </div>
    </div>
  )
}

describe("useOverflowCarousel drag to scroll", () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  function setup(dragToScroll?: boolean) {
    vi.stubGlobal(
      "ResizeObserver",
      class {
        observe() {}
        disconnect() {}
      },
    )
    const onCardClick = vi.fn()
    const view = render(<Scroller dragToScroll={dragToScroll} onCardClick={onCardClick} />)
    const scroller = view.getByTestId("scroller") as HTMLDivElement
    scroller.scrollBy = vi.fn()
    const [cardA, cardB] = [view.getByText("Card A"), view.getByText("Card B")]
    vi.spyOn(scroller, "getBoundingClientRect").mockReturnValue({ left: 0 } as DOMRect)
    // After the drag below, card B sits 30px past the scroller's start edge.
    vi.spyOn(cardA, "getBoundingClientRect").mockReturnValue({ left: -290 } as DOMRect)
    vi.spyOn(cardB, "getBoundingClientRect").mockReturnValue({ left: 30 } as DOMRect)
    return { scroller, cardA, onCardClick }
  }

  it("scrolls with a mouse drag, settles on the nearest card, and swallows the release click", () => {
    const { scroller, cardA, onCardClick } = setup(true)
    scroller.scrollLeft = 100

    fireEvent.pointerDown(cardA, { pointerId: 1, pointerType: "mouse", button: 0, clientX: 400 })
    fireEvent.pointerMove(cardA, { pointerId: 1, pointerType: "mouse", clientX: 250 })
    expect(scroller.scrollLeft).toBe(250)
    expect(scroller.style.scrollSnapType).toBe("none")

    fireEvent.pointerUp(cardA, { pointerId: 1, pointerType: "mouse", clientX: 250 })
    fireEvent.click(cardA)

    expect(onCardClick).not.toHaveBeenCalled()
    expect(scroller.scrollBy).toHaveBeenCalledWith({ left: 30, behavior: "smooth" })
  })

  it("keeps plain clicks and ignores touch, which scrolls natively", () => {
    const { scroller, cardA, onCardClick } = setup(true)
    scroller.scrollLeft = 100

    fireEvent.pointerDown(cardA, { pointerId: 1, pointerType: "touch", button: 0, clientX: 400 })
    fireEvent.pointerMove(cardA, { pointerId: 1, pointerType: "touch", clientX: 250 })
    fireEvent.pointerUp(cardA, { pointerId: 1, pointerType: "touch", clientX: 250 })
    expect(scroller.scrollLeft).toBe(100)

    fireEvent.pointerDown(cardA, { pointerId: 2, pointerType: "mouse", button: 0, clientX: 400 })
    fireEvent.pointerUp(cardA, { pointerId: 2, pointerType: "mouse", clientX: 402 })
    fireEvent.click(cardA)
    expect(onCardClick).toHaveBeenCalledTimes(1)
  })

  it("does not drag unless opted in", () => {
    const { scroller, cardA } = setup(false)
    scroller.scrollLeft = 100

    fireEvent.pointerDown(cardA, { pointerId: 1, pointerType: "mouse", button: 0, clientX: 400 })
    fireEvent.pointerMove(cardA, { pointerId: 1, pointerType: "mouse", clientX: 250 })
    expect(scroller.scrollLeft).toBe(100)
  })
})
