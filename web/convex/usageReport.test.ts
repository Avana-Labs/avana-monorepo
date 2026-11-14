// @vitest-environment edge-runtime

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

function tx(wallet: string, product: "lend" | "swap", status: "success" | "failed" = "success") {
  return {
    wallet,
    product,
    kind: product === "swap" ? "swap" : "deposit",
    status,
    requestedAmountUsd6: "1000000",
    executedAmountUsd6: "1000000",
    amountUsd: 1,
    syntheticTxHash: `0x${Math.random().toString(16).slice(2)}`,
    simulated: true,
    at: Date.now(),
  }
}

describe("usageReport.summary", () => {
  test("counts wallets, onboarding and successful transactions by product per day", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    const today = new Date(now).toISOString().slice(0, 10)
    await t.run(async (ctx) => {
      await ctx.db.insert("sandboxProfiles", {
        wallet: "0xa",
        createdAt: now,
        seedVersion: 1,
        onboardingStep: "done",
        onboardedAt: now,
      })
      await ctx.db.insert("sandboxProfiles", {
        wallet: "0xb",
        createdAt: now,
        seedVersion: 1,
        onboardingStep: "eligible",
      })
      await ctx.db.insert("transactions", tx("0xa", "lend"))
      await ctx.db.insert("transactions", tx("0xa", "swap"))
      await ctx.db.insert("transactions", tx("0xb", "swap"))
      await ctx.db.insert("transactions", tx("0xb", "lend", "failed"))
    })

    const report = await t.query(internal.usageReport.summary, { days: 7 })

    expect(report.totals).toEqual({
      wallets: 2,
      onboarded: 1,
      transactionsInWindow: 3,
      byProductInWindow: { lend: 1, swap: 2 },
    })
    expect(report.daily[today]).toEqual({
      newWallets: 2,
      onboarded: 1,
      activeWallets: 2,
      transactions: 3,
      byProduct: { lend: 1, swap: 2 },
    })
    expect(report.truncated).toBe(false)
  })
})
