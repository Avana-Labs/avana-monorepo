import { afterEach, describe, expect, it, vi } from "vitest"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"

describe("resolveDataSourceMode", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("defaults to live Convex data", () => {
    vi.stubEnv("AVANA_DATA_SOURCE", "")
    expect(resolveDataSourceMode()).toBe("live")
  })

  it("enables mock data when explicitly requested", () => {
    vi.stubEnv("AVANA_DATA_SOURCE", "mock")
    expect(resolveDataSourceMode()).toBe("mock")
  })

  it("keeps live Convex data for the Playwright open-gate browser test wallet", () => {
    // Open-gate is a session shortcut (skip SIWE, use shared dev wallet). The data source
    // stays live — dev work exercises the same Convex reads as production.
    vi.stubEnv("AVANA_DATA_SOURCE", "live")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE", "1")
    expect(resolveDataSourceMode()).toBe("live")
  })

  it("keeps live Convex data when the dev open-gate flag is enabled", () => {
    // Open-gate no longer implies mock — the shared dev wallet reads/writes real Convex
    // against the same prod deployment other wallets use.
    vi.stubEnv("AVANA_DATA_SOURCE", "live")
    vi.stubEnv("NEXT_PUBLIC_DEV_OPEN_GATE", "1")
    expect(resolveDataSourceMode()).toBe("live")
  })
})
