import { act, renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const captureException = vi.hoisted(() => vi.fn(async () => "event-id"))
vi.mock("@/app/lib/monitoring/sentry-client", () => ({ captureException }))

import {
  MARKETS_LOAD_TIMEOUT_MS,
  resetMarketsOutageReport,
  useMarketsLoadState,
} from "@/app/lib/avana-session/use-markets-load-state"

beforeEach(() => {
  vi.useFakeTimers()
  captureException.mockClear()
  resetMarketsOutageReport()
})
afterEach(() => vi.useRealTimers())

describe("useMarketsLoadState", () => {
  it("fails at once without a Convex URL and reports nothing", () => {
    const { result } = renderHook(() => useMarketsLoadState(false, 0, false))
    expect(result.current).toBe("failed")
    act(() => vi.advanceTimersByTime(MARKETS_LOAD_TIMEOUT_MS * 2))
    expect(captureException).not.toHaveBeenCalled()
  })

  it("is ready once markets arrive", () => {
    const { result } = renderHook(() => useMarketsLoadState(true, 0, true))
    expect(result.current).toBe("ready")
  })

  it("fails after the timeout and reports the outage once per session", () => {
    const { result, rerender } = renderHook(({ attempt }) => useMarketsLoadState(false, attempt, true), {
      initialProps: { attempt: 0 },
    })
    expect(result.current).toBe("loading")
    act(() => vi.advanceTimersByTime(MARKETS_LOAD_TIMEOUT_MS))
    expect(result.current).toBe("failed")
    expect(captureException).toHaveBeenCalledTimes(1)

    // Try again restarts the wait; a second timeout does not report again.
    rerender({ attempt: 1 })
    expect(result.current).toBe("loading")
    act(() => vi.advanceTimersByTime(MARKETS_LOAD_TIMEOUT_MS))
    expect(result.current).toBe("failed")
    expect(captureException).toHaveBeenCalledTimes(1)
  })
})
