import { act, cleanup, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { canLoadSpeculatively, useSpeculativeLoading } from "../speculative-loading"

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

function setup(network?: Record<string, unknown>) {
  const connection = Object.assign(new EventTarget(), network)
  vi.stubGlobal("navigator", { onLine: true, connection })
  vi.spyOn(document, "readyState", "get").mockReturnValue("complete")
  return connection
}

describe("speculative downloads", () => {
  it.each([
    { saveData: true },
    { effectiveType: "slow-2g" },
    { effectiveType: "2g" },
    { effectiveType: "3g" },
    { downlink: 1 },
  ])("avoids downloads on constrained connections: %j", (network) => {
    setup(network)
    expect(canLoadSpeculatively()).toBe(false)
  })

  it("waits for the current page to finish loading", () => {
    setup({ effectiveType: "4g", downlink: 10 })
    const ready = vi.spyOn(document, "readyState", "get").mockReturnValue("interactive")
    const { result } = renderHook(useSpeculativeLoading)
    expect(result.current).toBe(false)
    act(() => {
      ready.mockReturnValue("complete")
      window.dispatchEvent(new Event("load"))
    })
    expect(result.current).toBe(true)
  })

  it("responds when data saver is enabled during the session", () => {
    const connection = setup({ saveData: false })
    const { result } = renderHook(useSpeculativeLoading)
    expect(result.current).toBe(true)
    act(() => {
      Object.assign(connection, { saveData: true })
      connection.dispatchEvent(new Event("change"))
    })
    expect(result.current).toBe(false)
  })

  it("supports browsers without the Network Information API and stops when offline", () => {
    setup()
    vi.stubGlobal("navigator", { onLine: true })
    const { result } = renderHook(useSpeculativeLoading)
    expect(result.current).toBe(true)
    act(() => {
      vi.stubGlobal("navigator", { onLine: false })
      window.dispatchEvent(new Event("offline"))
    })
    expect(result.current).toBe(false)
  })
})
