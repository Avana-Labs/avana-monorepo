// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The intent tracker runs only while a chain has open intents (intents.ts): a wake schedules one run per chain, a run
// schedules the next while intents stay open and stops the chain's tracker once none are, a run that lost the chain to
// a newer one schedules nothing, and the 5-minute wake restarts a chain whose run was lost.

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"
import { TRACKER_LOST_MS } from "../../convex/intents"

const modules = import.meta.glob("../../convex/**/*.*s")
const ADDR = "0x00000000000000000000000000000000000000aa"
const WALLET = "0x00000000000000000000000000000000000000bb"

function setup() {
  const t = convexTest(schema, modules)
  const seed = (open: boolean) =>
    t.run(async (ctx) => {
      await ctx.db.insert("deployments", { chainId: 1, chainSlug: "ethereum", hubs: [], lendSpokes: [], cdpSpokes: [], firstLossReserves: [], explorerUrl: "", nativeUsdFeed: ADDR, release: "r" })
      if (open) await ctx.db.insert("intents", { wallet: WALLET, chainId: 1, txHash: `0x${"11".repeat(32)}`, kind: "borrow", status: "pending", submittedAt: Date.now(), open: true, checkedAt: 0, updatedAt: Date.now() })
    })
  const tracker = () => t.run((ctx) => ctx.db.query("intentTrackers").withIndex("by_chain", (q) => q.eq("chainId", 1)).unique())
  const scheduled = () => t.run(async (ctx) => (await ctx.db.system.query("_scheduled_functions").collect()).filter((f) => f.name.startsWith("intents") && f.state.kind === "pending").length)
  return { t, seed, tracker, scheduled }
}

describe("intent tracker", () => {
  test("a chain without open intents gets no tracker", async () => {
    const { t, seed, tracker, scheduled } = setup()
    await seed(false)
    await t.mutation(internal.intents.wake, {})
    expect(await tracker()).toBeNull()
    expect(await scheduled()).toBe(0)
  })

  test("a wake schedules one run per chain, and a second wake adds none", async () => {
    const { t, seed, tracker, scheduled } = setup()
    await seed(true)
    await t.mutation(internal.intents.wake, {})
    await t.mutation(internal.intents.wake, {})
    expect(await tracker()).not.toBeNull()
    expect(await scheduled()).toBe(1)
  })

  test("a run schedules the next while intents are open and stops the tracker once none are", async () => {
    const { t, seed, tracker, scheduled } = setup()
    await seed(true)
    await t.mutation(internal.intents.wake, {})
    const first = (await tracker())!.run
    await t.mutation(internal.intents.afterTrack, { chainId: 1, run: first })
    expect(await scheduled()).toBe(2)
    const second = (await tracker())!.run
    await t.run(async (ctx) => {
      for (const i of await ctx.db.query("intents").collect()) await ctx.db.patch(i._id, { open: false })
    })
    await t.mutation(internal.intents.afterTrack, { chainId: 1, run: second })
    expect(await tracker()).toBeNull()
  })

  test("a run that lost the chain to a newer one schedules nothing", async () => {
    const { t, seed, tracker, scheduled } = setup()
    await seed(true)
    await t.mutation(internal.intents.wake, {})
    const current = (await tracker())!.run
    await t.mutation(internal.intents.afterTrack, { chainId: 1, run: current - 1 })
    expect(await scheduled()).toBe(1)
    expect((await tracker())!.run).toBe(current)
  })

  test("the wake restarts a chain whose run was lost", async () => {
    const { t, seed, tracker, scheduled } = setup()
    await seed(true)
    await t.run((ctx) => ctx.db.insert("intentTrackers", { chainId: 1, run: Date.now() - TRACKER_LOST_MS - 1 }))
    await t.mutation(internal.intents.wake, {})
    expect(await scheduled()).toBe(1)
    expect(Date.now() - (await tracker())!.run).toBeLessThan(TRACKER_LOST_MS)
  })
})
