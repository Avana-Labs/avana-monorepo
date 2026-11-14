import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { applyLiveRates, exchangeRateFor } from "@/app/lib/currency/rates"
import { currencyContext } from "@/app/lib/currency/format"

describe("live FX overlay (rates.ts)", () => {
  it("overrides the baseline once a live rate is applied, and reflects in the ctx", () => {
    // Baseline for EUR is 0.92; apply a live rate and the resolver + ctx follow it.
    applyLiveRates({ EUR: 0.87 })
    expect(exchangeRateFor("EUR")).toBe(0.87)
    expect(currencyContext("EUR").rate).toBe(0.87)
  })

  it("ignores non-positive / non-finite rates and keeps the baseline", () => {
    applyLiveRates({ GBP: 0 })
    applyLiveRates({ GBP: Number.NaN })
    // Falls back to the baseline (0.79) since nothing valid was applied.
    expect(exchangeRateFor("GBP")).toBe(0.79)
  })

  it("USD is always identity", () => {
    applyLiveRates({ USD: 2 })
    expect(exchangeRateFor("USD")).toBe(1)
    expect(currencyContext("USD").rate).toBe(1)
  })
})

describe("fetchLiveRates (exchange-rates.ts)", () => {
  const realFetch = globalThis.fetch

  beforeEach(() => {
    window.localStorage.clear()
    vi.resetModules()
  })

  afterEach(() => {
    globalThis.fetch = realFetch
    vi.restoreAllMocks()
  })

  it("applies supported rates from a successful response and caches them", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        result: "success",
        rates: { USD: 1, EUR: 0.85, JPY: 160, ZZZ: 99, BADVALUE: -1 },
      }),
    }) as unknown as typeof fetch

    const { fetchLiveRates } = await import("@/app/lib/currency/exchange-rates")
    const { exchangeRateFor: resolve } = await import("@/app/lib/currency/rates")

    const updated = await fetchLiveRates({ force: true })
    expect(updated).toBe(true)
    expect(resolve("EUR")).toBe(0.85)
    expect(resolve("JPY")).toBe(160)
    // Cache was written and only holds supported codes.
    const cached = JSON.parse(window.localStorage.getItem("avana-fx-rates") ?? "{}")
    expect(cached.rates.EUR).toBe(0.85)
    expect(cached.rates.ZZZ).toBeUndefined()
  })

  it("returns false and keeps the baseline when the network fails", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error("offline")) as unknown as typeof fetch

    const { fetchLiveRates } = await import("@/app/lib/currency/exchange-rates")
    const updated = await fetchLiveRates({ force: true })
    expect(updated).toBe(false)
  })

  it("returns false on an unsuccessful API result", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ result: "error", rates: null }),
    }) as unknown as typeof fetch

    const { fetchLiveRates } = await import("@/app/lib/currency/exchange-rates")
    expect(await fetchLiveRates({ force: true })).toBe(false)
  })
})
