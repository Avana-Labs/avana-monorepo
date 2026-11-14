// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test, vi } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"
import { classifyFxStatus, FX_INVALID_AFTER_MS, FX_STALE_AFTER_MS, SUPPORTED_FX_CURRENCIES } from "../fx"

const modules = import.meta.glob("../**/*.*s")

const okResponse = (rates: Record<string, number>, unix = Math.floor(Date.now() / 1000)) =>
  ({ ok: true, json: async () => ({ result: "success", rates, time_last_update_unix: unix }) }) as unknown as Response

describe("classifyFxStatus", () => {
  test("fresh < stale < invalid", () => {
    expect(classifyFxStatus(0)).toBe("fresh")
    expect(classifyFxStatus(FX_STALE_AFTER_MS)).toBe("stale")
    expect(classifyFxStatus(FX_INVALID_AFTER_MS)).toBe("invalid")
  })
})

describe("refreshFxRates — validated Convex FX layer (C17)", () => {
  test("fetches, validates, and stores supported-currency rates with USD forced to 1", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => okResponse({ USD: 1, EUR: 0.92, JPY: 151, INR: 83.4, CNY: 7.18 })),
    )
    const result = await t.action(internal.fx.refreshFxRates, {})
    expect(result.written).toBeGreaterThan(0)
    const { rates, status } = await t.query(api.fx.getFxRates, {})
    const byCode = new Map(rates.map((r) => [r.currency, r]))
    expect(byCode.get("USD")?.usdPerUnit).toBe(1)
    expect(byCode.get("EUR")?.usdPerUnit).toBe(0.92)
    expect(byCode.get("USD")?.status).toBe("fresh")
    expect(status.count).toBeGreaterThan(0)
  })

  test("drops non-finite / non-positive quotes but keeps the valid ones", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => okResponse({ USD: 1, EUR: 0.92, JPY: 0, INR: -5, CNY: Number.NaN })),
    )
    await t.action(internal.fx.refreshFxRates, {})
    const { rates } = await t.query(api.fx.getFxRates, {})
    const codes = rates.map((r) => r.currency)
    expect(codes).toContain("USD")
    expect(codes).toContain("EUR")
    expect(codes).not.toContain("JPY")
    expect(codes).not.toContain("INR")
    expect(codes).not.toContain("CNY")
  })

  test("a failed fetch throws (recorded FAILED) and writes nothing", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: false, status: 502, json: async () => ({}) }) as unknown as Response),
    )
    await expect(t.action(internal.fx.refreshFxRates, {})).rejects.toThrow()
    const { rates } = await t.query(api.fx.getFxRates, {})
    expect(rates).toHaveLength(0)
  })

  test("an unsuccessful provider result is treated as a failure", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: true, json: async () => ({ result: "error", rates: null }) }) as unknown as Response),
    )
    await expect(t.action(internal.fx.refreshFxRates, {})).rejects.toThrow()
  })
})

describe("SUPPORTED_FX_CURRENCIES stays in sync with the app currency list", () => {
  test("matches CURRENCY_OPTIONS", async () => {
    const { CURRENCY_OPTIONS } = await import("@/app/components/display-preferences")
    const appCodes = new Set(CURRENCY_OPTIONS.map((o) => o.code))
    const fxCodes = new Set(SUPPORTED_FX_CURRENCIES)
    expect([...fxCodes].sort()).toEqual([...appCodes].sort())
  })
})
