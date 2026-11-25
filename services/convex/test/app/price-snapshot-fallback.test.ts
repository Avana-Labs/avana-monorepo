// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"
import { mergePriceRows } from "../../convex/prices"

const modules = import.meta.glob("../../convex/**/*.*s")

describe("mergePriceRows", () => {
  test("keeps the protocol's price, adds external prices for unpriced symbols, and aliases eth and weth", () => {
    const merged = mergePriceRows(
      [
        { symbol: "usdc", priceUsd: 1, source: "lendSpokeOracle" },
        { symbol: "weth", priceUsd: 3000, source: "lendSpokeOracle" },
      ],
      [
        { symbol: "usdc", priceUsd: 0.999, source: "defillama" },
        { symbol: "op", priceUsd: 2, source: "defillama" },
        { symbol: "eth", priceUsd: 3001, source: "defillama" },
      ],
    )
    expect(merged.map((r) => [r.symbol, r.priceUsd, r.source])).toEqual([
      ["usdc", 1, "lendSpokeOracle"],
      ["weth", 3000, "lendSpokeOracle"],
      ["op", 2, "defillama"],
      ["eth", 3001, "defillama"],
    ])
    expect(mergePriceRows([{ symbol: "weth", priceUsd: 3000 }], []).map((r) => [r.symbol, r.priceUsd])).toEqual([
      ["weth", 3000],
      ["eth", 3000],
    ])
  })
})

describe("prices.getPriceSnapshot", () => {
  test("serves DefiLlama prices when the protocol prices nothing, without moving the protocol's freshness", async () => {
    const t = convexTest(schema, modules)
    const updatedAt = Date.now()
    await t.mutation(internal.tokenPrices.upsertPrices, {
      rows: [
        { symbol: "usdc", llamaId: "ethereum:0xa0b8", priceUsd: 1, source: "defillama", updatedAt },
        { symbol: "op", llamaId: "coingecko:optimism", priceUsd: 2, source: "defillama", updatedAt },
      ],
    })
    const snapshot = await t.query(api.prices.getPriceSnapshot, {})
    expect(snapshot.prices.map((p) => [p.symbol, p.priceUsd, p.source, p.status])).toEqual([
      ["usdc", 1, "defillama", "fresh"],
      ["op", 2, "defillama", "fresh"],
    ])
    expect(snapshot.status.updatedAt).toBeNull()
  })
})
