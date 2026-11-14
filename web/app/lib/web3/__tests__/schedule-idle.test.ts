import { afterEach, describe, expect, it, vi } from "vitest"
import { scheduleIdle } from "@/app/lib/web3/schedule-idle"

describe("scheduleIdle", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    // @ts-expect-error test cleanup
    delete window.requestIdleCallback
    // @ts-expect-error test cleanup
    delete window.cancelIdleCallback
  })

  it("defers the callback to requestIdleCallback rather than running it synchronously", () => {
    let idleCb: (() => void) | null = null
    window.requestIdleCallback = vi.fn((cb: IdleRequestCallback) => {
      idleCb = () => cb({ didTimeout: false, timeRemaining: () => 0 } as IdleDeadline)
      return 7
    }) as unknown as typeof window.requestIdleCallback

    const run = vi.fn()
    scheduleIdle(run)

    // Not called synchronously — it waits for idle.
    expect(run).not.toHaveBeenCalled()
    expect(window.requestIdleCallback).toHaveBeenCalledTimes(1)

    // Fires when the browser goes idle.
    idleCb?.()
    expect(run).toHaveBeenCalledTimes(1)
  })

  it("cancel() cancels the pending idle callback", () => {
    const cancel = vi.fn()
    window.requestIdleCallback = vi.fn(() => 42) as unknown as typeof window.requestIdleCallback
    window.cancelIdleCallback = cancel as unknown as typeof window.cancelIdleCallback

    const stop = scheduleIdle(vi.fn())
    stop()
    expect(cancel).toHaveBeenCalledWith(42)
  })

  it("falls back to a timeout when requestIdleCallback is unavailable", () => {
    vi.useFakeTimers()
    // Ensure the API is absent (Safari).
    // @ts-expect-error test setup
    delete window.requestIdleCallback

    const run = vi.fn()
    const stop = scheduleIdle(run, 4000)
    expect(run).not.toHaveBeenCalled()
    vi.advanceTimersByTime(3999)
    expect(run).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(run).toHaveBeenCalledTimes(1)

    // cancel after fire is a no-op; cancel before fire prevents it.
    const run2 = vi.fn()
    const stop2 = scheduleIdle(run2, 8000)
    stop2()
    vi.advanceTimersByTime(8000)
    expect(run2).not.toHaveBeenCalled()

    stop()
    vi.useRealTimers()
  })
})
