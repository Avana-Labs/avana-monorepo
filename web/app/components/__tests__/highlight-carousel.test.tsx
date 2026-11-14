import { createRef } from "react"
import { act, cleanup, fireEvent, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { HighlightCarousel, type HighlightCarouselHandle } from "@/app/components/highlight-carousel"

describe("HighlightCarousel", () => {
  let frameId = 0
  let frames: Map<number, FrameRequestCallback>

  beforeEach(() => {
    frames = new Map()
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      frameId += 1
      frames.set(frameId, callback)
      return frameId
    })
    vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id))
    vi.stubGlobal(
      "ResizeObserver",
      class {
        constructor(private readonly callback: ResizeObserverCallback) {}
        observe() {
          this.callback([], this as unknown as ResizeObserver)
        }
        disconnect() {}
      },
    )
    Object.defineProperty(HTMLElement.prototype, "offsetWidth", {
      configurable: true,
      get: () => 380,
    })
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  function runNextFrame(time: number) {
    const [id, callback] = [...frames.entries()][0]
    frames.delete(id)
    act(() => callback(time))
  }

  it("advances at the speed calc but clamps a stalled frame (no lurch)", () => {
    const { container } = render(<HighlightCarousel durationSeconds={38} renderSequence={() => <div>Market</div>} />)
    const viewport = container.firstElementChild as HTMLDivElement
    const track = viewport.firstElementChild as HTMLDivElement

    // speed = offsetWidth(380) / durationSeconds(38) = 10px/s.
    runNextFrame(1_000) // seed the clock (no move)
    runNextFrame(1_050) // 50ms → 10 * 0.05 = 0.5px
    expect(track.style.transform).toBe("translate3d(-0.5px, 0, 0)")

    // A ~4s starved frame (heavy load) is clamped to 50ms, so it advances another
    // 0.5px — NOT ~40px. This is what stops the marquee lurching/shaking on load.
    runNextFrame(5_000)
    expect(track.style.transform).toBe("translate3d(-1px, 0, 0)")
  })

  it("stops scheduling frames while hovered and resumes from the same position", () => {
    const { container } = render(<HighlightCarousel durationSeconds={38} renderSequence={() => <div>Market</div>} />)
    const viewport = container.firstElementChild as HTMLDivElement
    const track = viewport.firstElementChild as HTMLDivElement

    runNextFrame(1_000) // seed
    runNextFrame(1_050) // 50ms → -0.5px
    fireEvent.mouseEnter(viewport)

    expect(frames.size).toBe(0)
    expect(track.style.transform).toBe("translate3d(-0.5px, 0, 0)")

    fireEvent.mouseLeave(viewport)
    expect(frames.size).toBe(1)
    expect(track.style.transform).toBe("translate3d(-0.5px, 0, 0)")
  })

  it("preserves its phase when a provider remounts the carousel", () => {
    const first = render(
      <HighlightCarousel syncKey="provider-remount" durationSeconds={38} renderSequence={() => <div>Market</div>} />,
    )
    const firstTrack = first.container.firstElementChild?.firstElementChild as HTMLDivElement

    runNextFrame(1_000)
    runNextFrame(1_050)
    expect(firstTrack.style.transform).toBe("translate3d(-0.5px, 0, 0)")

    first.unmount()
    const second = render(
      <HighlightCarousel syncKey="provider-remount" durationSeconds={38} renderSequence={() => <div>Market</div>} />,
    )
    const secondTrack = second.container.firstElementChild?.firstElementChild as HTMLDivElement

    expect(secondTrack.style.transform).toBe("translate3d(-0.5px, 0, 0)")
  })

  it("eases one card on arrow step instead of jumping", () => {
    const ref = createRef<HighlightCarouselHandle>()
    const { container } = render(
      <HighlightCarousel ref={ref} durationSeconds={38} renderSequence={() => <div>Market</div>} />,
    )
    const viewport = container.firstElementChild as HTMLDivElement
    const track = viewport.firstElementChild as HTMLDivElement
    const sequence = track.firstElementChild as HTMLDivElement
    vi.spyOn(sequence.firstElementChild as HTMLElement, "getBoundingClientRect").mockReturnValue({
      width: 200,
    } as DOMRect)

    runNextFrame(1_000)
    runNextFrame(2_000)
    expect(ref.current).not.toBeNull()
    act(() => ref.current?.step(1))
    runNextFrame(2_100)
    runNextFrame(2_200)

    const x = Number(/translate3d\((-?[\d.]+)px/.exec(track.style.transform)?.[1])
    expect(x).toBeLessThan(-20)
    expect(x).toBeGreaterThan(-222)
  })
  it("drags the track with the pointer and swallows the click that ends the drag", () => {
    const onCardClick = vi.fn()
    const { container, getByText } = render(
      <HighlightCarousel
        durationSeconds={38}
        renderSequence={(interactive) => (interactive ? <button onClick={onCardClick}>Market</button> : <div />)}
      />,
    )
    const viewport = container.firstElementChild as HTMLDivElement
    const track = viewport.firstElementChild as HTMLDivElement
    const card = getByText("Market")

    fireEvent.pointerDown(card, { pointerId: 1, pointerType: "mouse", button: 0, clientX: 300 })
    fireEvent.pointerMove(card, { pointerId: 1, pointerType: "mouse", clientX: 220 })
    expect(track.style.transform).toBe("translate3d(-80px, 0, 0)")
    // Dragging pauses the marquee.
    expect(frames.size).toBe(0)

    fireEvent.pointerUp(card, { pointerId: 1, pointerType: "mouse", clientX: 220 })
    fireEvent.click(card)
    expect(onCardClick).not.toHaveBeenCalled()

    // Dragging right past the start wraps into the loop instead of exposing a gap.
    fireEvent.pointerDown(card, { pointerId: 2, pointerType: "mouse", button: 0, clientX: 100 })
    fireEvent.pointerMove(card, { pointerId: 2, pointerType: "mouse", clientX: 200 })
    expect(track.style.transform).toBe("translate3d(-360px, 0, 0)")
  })

  it("keeps a click that moves less than the drag threshold", () => {
    const onCardClick = vi.fn()
    const { container, getByText } = render(
      <HighlightCarousel
        durationSeconds={38}
        renderSequence={(interactive) => (interactive ? <button onClick={onCardClick}>Market</button> : <div />)}
      />,
    )
    const track = (container.firstElementChild as HTMLDivElement).firstElementChild as HTMLDivElement
    const card = getByText("Market")

    fireEvent.pointerDown(card, { pointerId: 1, pointerType: "mouse", button: 0, clientX: 300 })
    fireEvent.pointerMove(card, { pointerId: 1, pointerType: "mouse", clientX: 297 })
    fireEvent.pointerUp(card, { pointerId: 1, pointerType: "mouse", clientX: 297 })
    fireEvent.click(card)

    expect(onCardClick).toHaveBeenCalledTimes(1)
    expect(track.style.transform).toBe("translate3d(0px, 0, 0)")
  })

  it("scrolls on horizontal trackpad swipes but leaves vertical wheel scrolling to the page", () => {
    const { container } = render(<HighlightCarousel durationSeconds={38} renderSequence={() => <div>Market</div>} />)
    const viewport = container.firstElementChild as HTMLDivElement
    const track = viewport.firstElementChild as HTMLDivElement

    const horizontal = new WheelEvent("wheel", { deltaX: 40, deltaY: 2, cancelable: true })
    viewport.dispatchEvent(horizontal)
    expect(horizontal.defaultPrevented).toBe(true)
    expect(track.style.transform).toBe("translate3d(-40px, 0, 0)")

    const vertical = new WheelEvent("wheel", { deltaX: 0, deltaY: 60, cancelable: true })
    viewport.dispatchEvent(vertical)
    expect(vertical.defaultPrevented).toBe(false)
    expect(track.style.transform).toBe("translate3d(-40px, 0, 0)")
  })
})
