import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { preferLive, preferLiveOrNull } from "@/app/lib/data/providers/prefer-live"

describe("preferLive / preferLiveOrNull", () => {
  const originalEnv = process.env.NODE_ENV

  beforeEach(() => {
    vi.restoreAllMocks()
  })
  afterEach(() => {
    process.env.NODE_ENV = originalEnv
  })

  it("returns the live value when present (no warning)", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(preferLive({ id: "live" }, { id: "mock" }, "ctx-a")).toEqual({ id: "live" })
    expect(preferLiveOrNull({ id: "live" }, "ctx-b")).toEqual({ id: "live" })
    expect(warn).not.toHaveBeenCalled()
  })

  it("preferLive falls back to mock, preferLiveOrNull yields null (runtime === `?? fallback`)", () => {
    process.env.NODE_ENV = "production" // silence the dev warn to isolate runtime behavior
    expect(preferLive(null, { id: "mock" }, "ctx-c")).toEqual({ id: "mock" })
    expect(preferLive(undefined, { id: "mock" }, "ctx-d")).toEqual({ id: "mock" })
    expect(preferLiveOrNull(null, "ctx-e")).toBeNull()
    expect(preferLiveOrNull(undefined, "ctx-f")).toBeNull()
  })

  it("treats falsy-but-present values (0, '', false) as live, not missing", () => {
    process.env.NODE_ENV = "production"
    expect(preferLive(0, 99, "ctx-zero")).toBe(0)
    expect(preferLive("", "mock", "ctx-empty")).toBe("")
    expect(preferLive(false, true, "ctx-false")).toBe(false)
  })

  it("warns once per context in development, and is silent otherwise", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    process.env.NODE_ENV = "development"
    preferLive(null, "mock", "dev-context-unique-1")
    preferLive(null, "mock", "dev-context-unique-1") // deduped
    expect(warn).toHaveBeenCalledTimes(1)
    expect(warn.mock.calls[0]![0]).toContain("[prefer-live]")

    warn.mockClear()
    process.env.NODE_ENV = "production"
    preferLive(null, "mock", "prod-context-unique-1")
    process.env.NODE_ENV = "test"
    preferLive(null, "mock", "test-context-unique-1")
    expect(warn).not.toHaveBeenCalled()
  })
})
