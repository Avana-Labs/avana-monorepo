// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Older activity for the dashboard: block times kept by chain and block number, and history records decoded as the
// import decodes them into the wallet's own rows, leaving out the events Convex still holds.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import type { ExportRecord } from "@avana/services-common/export"
import { FIXTURE_LEND, fixtureHubAsset } from "@avana/services-common/fixtures"
import { internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0x00000000000000000000000000000000000000a1"
const OTHER = "0x00000000000000000000000000000000000000e2"
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}`

const supply = (block: number, user: string, logIndex = 0): ExportRecord =>
  ({
    key: `1:${H(block)}:${logIndex}`,
    kind: "AaveSpoke.Supply",
    blockNumber: String(block),
    blockHash: H(block + 10_000),
    txHash: H(block),
    logIndex,
    address: FIXTURE_LEND,
    args: { user, reserveId: "0", suppliedAmount: "1500000000" },
  }) as ExportRecord

describe("block times", () => {
  test("are kept by chain and block number, and a new hash replaces the row", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.wallet.history.storeBlockTimes, { chainId: 1, rows: [{ number: "100", hash: H(1), timestampMs: 1_000 }] })
    await t.mutation(internal.wallet.history.storeBlockTimes, { chainId: 8453, rows: [{ number: "100", hash: H(2), timestampMs: 2_000 }] })
    expect(await t.query(internal.wallet.history.cachedBlockTimes, { chainId: 1, numbers: ["100", "101"] })).toEqual([{ number: "100", hash: H(1), timestampMs: 1_000 }])

    await t.mutation(internal.wallet.history.storeBlockTimes, { chainId: 1, rows: [{ number: "100", hash: H(3), timestampMs: 3_000 }] })
    expect(await t.query(internal.wallet.history.cachedBlockTimes, { chainId: 1, numbers: ["100"] })).toEqual([{ number: "100", hash: H(3), timestampMs: 3_000 }])
    expect(await t.run((ctx) => ctx.db.query("blockTimestamps").collect())).toHaveLength(2)
  })
})

describe("older rows", () => {
  test("are the wallet's own events, decoded onto their page without a USD value, minus those Convex holds", async () => {
    const t = convexTest(schema, modules)
    const held = supply(300, WALLET)
    await t.run(async (ctx) => {
      await ctx.db.insert("deployments", { chainId: 1, chainSlug: "ethereum", lens: FIXTURE_LEND, hubs: [], lendSpokes: [FIXTURE_LEND], cdpSpokes: [], firstLossReserves: [], marketRegistry: FIXTURE_LEND, timelock: FIXTURE_LEND, explorerUrl: "https://etherscan.io", nativeUsdFeed: FIXTURE_LEND, release: "r" })
      await ctx.db.insert("hubAssets", { ...fixtureHubAsset, slug: "ethereum-usdc", updatedAt: 0, lendReserves: [...fixtureHubAsset.lendReserves] })
      await ctx.db.insert("ingestedLogs", { key: held.key, chainId: 1, kind: held.kind, blockNumber: held.blockNumber, blockHash: held.blockHash, txHash: held.txHash, logIndex: 0, address: FIXTURE_LEND, at: 0, args: held.args, wallet: WALLET })
    })
    const records = [
      held,
      supply(200, WALLET),
      supply(150, OTHER),
      { ...supply(120, WALLET), kind: "AaveAdapter.UserProxyCreated", args: { wallet: WALLET, marketId: "1", spoke: FIXTURE_LEND, proxy: OTHER } },
    ]
    const rows = await t.query(internal.wallet.history.olderRows, { chainId: 1, wallet: WALLET, records })
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      blockNumber: "200",
      blockHash: H(10_200),
      row: { id: `1:${H(200)}:0`, kind: "supply", amountLabel: "—", chainId: 1, page: { scope: "lend", slug: "ethereum-usdc" }, href: `https://etherscan.io/tx/${H(200)}` },
    })
    expect(rows[0]!.row.amountUsd).toBeUndefined()
    expect(rows[0]!.row.tokenAmountLabel).toMatch(/^1,500 /)
  })

  test("are empty for a chain that is not served", async () => {
    const t = convexTest(schema, modules)
    expect(await t.query(internal.wallet.history.olderRows, { chainId: 1, wallet: WALLET, records: [supply(200, WALLET)] })).toEqual([])
  })
})
