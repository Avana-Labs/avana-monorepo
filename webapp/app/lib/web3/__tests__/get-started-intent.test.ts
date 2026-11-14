// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest"
import { clearGetStartedIntent, hasGetStartedIntent, markGetStartedIntent } from "@/app/lib/web3/get-started-intent"

afterEach(() => {
  vi.useRealTimers()
  window.sessionStorage.clear()
})

describe("Get Started intent", () => {
  it("is absent until a Get Started click records it", () => {
    expect(hasGetStartedIntent()).toBe(false)
    markGetStartedIntent()
    expect(hasGetStartedIntent()).toBe(true)
  })

  it("expires so an abandoned connect never redirects a much later sign-in", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-24T12:00:00Z"))
    markGetStartedIntent()
    vi.setSystemTime(new Date("2026-09-24T12:09:00Z"))
    expect(hasGetStartedIntent()).toBe(true)
    vi.setSystemTime(new Date("2026-09-24T12:11:00Z"))
    expect(hasGetStartedIntent()).toBe(false)
  })

  it("is consumed once handled", () => {
    markGetStartedIntent()
    clearGetStartedIntent()
    expect(hasGetStartedIntent()).toBe(false)
  })
})
