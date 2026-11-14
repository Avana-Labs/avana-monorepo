// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test, vi } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"
import { classifyPriceStatus, parseLlamaId, PRICE_INVALID_AFTER_MS, PRICE_STALE_AFTER_MS } from "../../convex/tokenPrices"

const modules = import.meta.glob("../../convex/**/*.*s")

describe("parseLlamaId — chain/contract identity (C1)", () => {
  test("parses ethereum:0x… into chainId + lowercased contract", () => {
    expect(parseLlamaId("ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")).toEqual({
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    })
  })
  test("maps base/arbitrum/optimism chain names", () => {
    expect(parseLlamaId("base:0xabc").chainId).toBe(8453)
    expect(parseLlamaId("arbitrum:0xabc").chainId).toBe(42161)
  })
  test("coingecko slugs carry no contract/chain", () => {
    expect(parseLlamaId("coingecko:ethereum")).toEqual({})
  })
})

describe("classifyPriceStatus — freshness thresholds (C2)", () => {
  test("fresh below stale, stale below invalid, invalid beyond", () => {
    expect(classifyPriceStatus(0)).toBe("fresh")
    expect(classifyPriceStatus(PRICE_STALE_AFTER_MS - 1)).toBe("fresh")
    expect(classifyPriceStatus(PRICE_STALE_AFTER_MS)).toBe("stale")
    expect(classifyPriceStatus(PRICE_INVALID_AFTER_MS - 1)).toBe("stale")
    expect(classifyPriceStatus(PRICE_INVALID_AFTER_MS)).toBe("invalid")
  })
})

describe("refreshPrices populates identity + lineage (C1/C2)", () => {
  test("stores chainId/contractAddress/status for a fresh quote", async () => {
    const t = convexTest(schema, modules)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({
          coins: {
            "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48": { price: 1.0, decimals: 6, confidence: 0.99 },
            "coingecko:ethereum": { price: 3210.5, decimals: 18, confidence: 0.98 },
          },
        }),
      })) as unknown as typeof fetch,
    )
    await t.action(internal.tokenPrices.refreshPrices, {})
    const prices = await t.query(api.tokenPrices.getPrices, {})
    const usdc = prices.find((p) => p.symbol === "usdc")
    expect(usdc?.chainId).toBe(1)
    expect(usdc?.contractAddress).toBe("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    expect(usdc?.status).toBe("fresh")
    // Native ETH via coingecko slug: no contract, still priced + fresh.
    const eth = prices.find((p) => p.symbol === "eth")
    expect(eth?.contractAddress).toBeUndefined()
    expect(eth?.status).toBe("fresh")
  })
})
