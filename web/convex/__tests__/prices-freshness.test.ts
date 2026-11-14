// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test, vi } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"
import { PRICE_INVALID_AFTER_MS, PRICE_STALE_AFTER_MS } from "../prices"

const modules = import.meta.glob("../**/*.*s")

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe("getPriceStatus surfaces price freshness", () => {
  // getPriceStatus returns only the raw updatedAt; the client derives stale/ageMs from a
  // ticking clock (see app/lib/prices token-prices-context + its test). These assert the
  // query exposes the correct last-refresh time to derive from.
  test("no prices yet → updatedAt null (nothing served)", async () => {
    const t = convexTest(schema, modules)
    const status = await t.query(api.prices.getPriceStatus, {})
    expect(status.count).toBe(0)
    expect(status.updatedAt).toBeNull()
    expect(status.staleAfterMs).toBe(PRICE_STALE_AFTER_MS)
  })

  test("returns prices and freshness in one reactive snapshot", async () => {
    const t = convexTest(schema, modules)
    const updatedAt = Date.now()
    await t.mutation(internal.prices.upsertPrices, {
      rows: [
        {
          symbol: "eth",
          llamaId: "coingecko:ethereum",
          priceUsd: 3200,
          source: "defillama",
          updatedAt,
        },
      ],
    })

    const snapshot = await t.query(api.prices.getPriceSnapshot, {})
    expect(snapshot.prices).toHaveLength(1)
    expect(snapshot.prices[0]).toMatchObject({ symbol: "eth", priceUsd: 3200 })
    expect(snapshot.status.updatedAt).toBe(updatedAt)
    expect(snapshot.status).toMatchObject({
      staleAfterMs: PRICE_STALE_AFTER_MS,
      invalidAfterMs: PRICE_INVALID_AFTER_MS,
      count: 1,
    })
  })

  test("a fresh refresh reports a recent updatedAt", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ coins: { "coingecko:ethereum": { price: 3210.5, decimals: 18, confidence: 0.99 } } }),
      })) as unknown as typeof fetch,
    )
    await t.action(internal.prices.refreshPrices, {})

    const status = await t.query(api.prices.getPriceStatus, {})
    expect(status.count).toBeGreaterThan(0)
    expect(status.updatedAt).not.toBeNull()
    // Derived client-side: a just-written row is well within the stale window.
    expect(Date.now() - status.updatedAt!).toBeLessThan(PRICE_STALE_AFTER_MS)
  })

  test("a stalled cron leaves updatedAt older than the threshold (client flags stale)", async () => {
    const t = convexTest(schema, modules)
    // Land a price whose updatedAt is well past the stale threshold.
    await t.mutation(internal.prices.upsertPrices, {
      rows: [
        {
          symbol: "eth",
          llamaId: "coingecko:ethereum",
          priceUsd: 3000,
          source: "defillama",
          updatedAt: Date.now() - (PRICE_STALE_AFTER_MS + 60_000),
        },
      ],
    })
    const status = await t.query(api.prices.getPriceStatus, {})
    expect(status.updatedAt).not.toBeNull()
    expect(Date.now() - status.updatedAt!).toBeGreaterThan(PRICE_STALE_AFTER_MS)
  })

  test("a failing refresh throws so the scheduled run is recorded failed", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: false, status: 503, json: async () => ({}) })) as unknown as typeof fetch,
    )
    await expect(t.action(internal.prices.refreshPrices, {})).rejects.toThrow(/DefiLlama request failed: 503/)
  })

  test("a fetch that yields no usable prices is treated as a failure", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: true, json: async () => ({ coins: {} }) })) as unknown as typeof fetch,
    )
    await expect(t.action(internal.prices.refreshPrices, {})).rejects.toThrow(/no usable prices/)
  })
})
