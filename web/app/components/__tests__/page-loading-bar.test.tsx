import { act, cleanup, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { PageLoadingBar } from "../page-loading-bar"
import { triggerPageLoading } from "@/app/lib/page-loading"

const route = vi.hoisted(() => ({ pathname: "/borrow" }))
vi.mock("next/navigation", () => ({
  usePathname: () => route.pathname,
  useSearchParams: () => new URLSearchParams(),
}))

beforeEach(() => {
  vi.useFakeTimers()
  route.pathname = "/borrow"
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe("navigation progress", () => {
  it("does not flash or keep timers running for a cached transition", () => {
    const { container, rerender } = render(<PageLoadingBar />)
    act(() => {
      triggerPageLoading()
      vi.advanceTimersByTime(50)
    })
    route.pathname = "/lend"
    rerender(<PageLoadingBar />)
    act(() => vi.advanceTimersByTime(1000))
    expect(container.firstChild).toHaveClass("opacity-0")
    expect(vi.getTimerCount()).toBe(0)
  })

  it("shows a slow transition and completes immediately when the route arrives", () => {
    const { container, rerender } = render(<PageLoadingBar />)
    act(() => {
      triggerPageLoading()
      vi.advanceTimersByTime(120)
    })
    expect(container.firstChild).toHaveClass("opacity-100")
    route.pathname = "/lend"
    rerender(<PageLoadingBar />)
    expect(container.querySelector('[style*="scaleX(1)"]')).not.toBeNull()
    act(() => vi.advanceTimersByTime(180))
    expect(container.firstChild).toHaveClass("opacity-0")
  })

  it("does not let a previous completion timer hide the next navigation", () => {
    const { container, rerender, unmount } = render(<PageLoadingBar />)
    act(() => {
      triggerPageLoading()
      vi.advanceTimersByTime(120)
    })
    route.pathname = "/lend"
    rerender(<PageLoadingBar />)
    act(() => {
      triggerPageLoading()
      vi.advanceTimersByTime(200)
    })
    expect(container.firstChild).toHaveClass("opacity-100")
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })
})
