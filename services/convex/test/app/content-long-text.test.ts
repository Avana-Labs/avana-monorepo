// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A page's About text: the listing's full text when it gives one, beside its short description.

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { fixtureMarkets } from "@avana/services-common/fixtures"
import schema from "../../convex/schema"
import { readContent } from "../../convex/details"
import { loadWorld } from "../../convex/model"

const modules = import.meta.glob("../../convex/**/*.*s")

async function pageWith(longText?: string) {
  const t = convexTest(schema, modules)
  const m = fixtureMarkets[0]!
  await t.run(async (ctx) => {
    await ctx.db.insert("markets", { ...m, slug: "ethereum-usdc-usdt", updatedAt: 0 } as never)
    await ctx.db.insert("marketContent", {
      scope: "pool",
      chainId: m.chainId,
      key: m.marketId,
      slug: "ethereum-usdc-usdt",
      name: "USDC / USDT",
      description: "Short.",
      ...(longText ? { longText } : {}),
      stats: [],
      history: [],
      faqs: [],
      contentHash: "0x01",
      operationId: "0x02",
      loadedAt: 0,
    } as never)
  })
  return t.run(async (ctx) => readContent(ctx, await loadWorld(ctx), "pool", "ethereum-usdc-usdt"))
}

describe("page content", () => {
  test("carries the listing's full text when it gives one", async () => {
    expect(await pageWith("The full story.")).toMatchObject({ description: "Short.", longText: "The full story." })
    expect(await pageWith()).not.toHaveProperty("longText")
  })
})

describe("changelog sources", () => {
  test("name the event in words", async () => {
    const { changeSourceLabel } = await import("../../convex/details")
    expect(changeSourceLabel("AaveSpoke.AddDynamicReserveConfig")).toBe("Risk configuration added")
    expect(changeSourceLabel("AaveHub.UpdateAssetConfig")).toBe("Asset configuration update")
    expect(changeSourceLabel("Oracle.SetPriceFeed")).toBe("Set price feed")
  })
})
