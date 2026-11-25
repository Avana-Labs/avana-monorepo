// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Each integration's RiskModule numbers its own markets from 1, so a chain with two integrations lists two markets of
// the same ID. A market is (chain, integration, market ID): each gets its own row, page and lookup.

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { fixtureMarkets } from "@avana/services-common/fixtures"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"

const modules = import.meta.glob("../../convex/**/*.*s")

const base = fixtureMarkets[0]!
const OTHER_SPOKE = "0x00000000000000000000000000000000000000e9"
const snapshot = {
  chainId: base.chainId,
  blockNumber: base.blockNumber,
  timestamp: 0,
  hubs: [],
  hubAssets: [],
  slices: [],
  spokeReserves: [],
  markets: [base, { ...base, integrationId: 3, spoke: OTHER_SPOKE }],
}

describe("market identity", () => {
  test("two integrations' markets of one ID are two rows with their own pages", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.ingest.apply.applySnapshot, { snapshot })
    // A second run replaces each row in place.
    await t.mutation(internal.ingest.apply.applySnapshot, { snapshot })
    const rows = await t.run(async (ctx) => ctx.db.query("markets").collect())
    expect(rows.map((m) => [m.integrationId, m.marketId, m.spoke, m.slug]).sort()).toEqual([
      [1, base.marketId, base.spoke, `ethereum-market-1-${base.marketId}`],
      [3, base.marketId, OTHER_SPOKE, `ethereum-market-3-${base.marketId}`],
    ])
    const got = await t.query(api.collateralMarkets.get, { chainId: base.chainId, integrationId: 3, marketId: base.marketId })
    expect(got?.market.spoke).toBe(OTHER_SPOKE)
    // Without the integration, an ID two integrations list is refused rather than answered with either.
    await expect(t.query(api.collateralMarkets.get, { chainId: base.chainId, marketId: base.marketId })).rejects.toThrow(/pass integrationId/)
  })
})
