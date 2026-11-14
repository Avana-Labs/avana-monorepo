import { afterEach, describe, expect, it, vi } from "vitest"
import { canonicalPriceUsd, resetCanonicalPrices } from "@/app/lib/prices/canonical"

// Control the server-side oracle fetch so the test never touches a real Convex deployment.
const { fetchTokenPrices } = vi.hoisted(() => ({ fetchTokenPrices: vi.fn() }))
vi.mock("@/app/lib/prices/server-snapshot", () => ({ fetchTokenPrices }))

// unstable_cache needs the Next server cache context, which is absent in a plain unit test; make it
// a passthrough so the overlay logic under test runs against the mocked fetch directly. In the real
// server runtime it caches the result across requests (that is the C3 TTFB win) but returns the
// same value, so the behavior asserted here is unchanged.
vi.mock("next/cache", () => ({ unstable_cache: (fn: (...args: never[]) => unknown) => fn }))

import { loadServerTokenPrices } from "@/app/lib/prices/server-hydrate"
import { SERVER_SEED_WAIT_MS } from "@/app/lib/performance/server-seed"

afterEach(() => {
  resetCanonicalPrices()
  fetchTokenPrices.mockReset()
  vi.useRealTimers()
})

describe("loadServerTokenPrices", () => {
  it("releases SSR after the deadline without applying late oracle prices", async () => {
    vi.useFakeTimers()
    let resolve!: (prices: Record<string, number>) => void
    fetchTokenPrices.mockImplementation(() => new Promise((done) => (resolve = done)))
    const seed = loadServerTokenPrices()
    await vi.advanceTimersByTimeAsync(SERVER_SEED_WAIT_MS)
    await expect(seed).resolves.toEqual({})
    resolve({ aave: 88.25 })
    await vi.advanceTimersByTimeAsync(0)
    expect(canonicalPriceUsd("AAVE")).toBe(105)
  })

  it("overlays live oracle prices onto the canonical store (fixture -> live)", async () => {
    // Sanity: before hydrate the store is the deterministic fixture.
    expect(canonicalPriceUsd("AAVE")).toBe(105)

    // fetchTokenPrices emits lowercase symbol keys, like the Convex query does.
    fetchTokenPrices.mockResolvedValue({ aave: 88.25, weth: 1905.92 })
    await loadServerTokenPrices()

    expect(canonicalPriceUsd("AAVE")).toBe(88.25)
    expect(canonicalPriceUsd("WETH")).toBe(1905.92)
  })

  it("keeps the fixture when the oracle is unavailable (null)", async () => {
    fetchTokenPrices.mockResolvedValue(null)
    await loadServerTokenPrices()
    expect(canonicalPriceUsd("AAVE")).toBe(105)
  })

  it("never throws when the fetch rejects, leaving the fixture intact", async () => {
    fetchTokenPrices.mockRejectedValue(new Error("convex unreachable"))
    await expect(loadServerTokenPrices()).resolves.toEqual({})
    expect(canonicalPriceUsd("AAVE")).toBe(105)
  })
})
