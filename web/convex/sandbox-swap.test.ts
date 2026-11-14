// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xDdD0000000000000000000000000000000000002"

function swapIntent(intentId: string, overrides: Record<string, unknown> = {}) {
  return {
    wallet: WALLET,
    intentId,
    inputAssetId: "eth",
    outputAssetId: "usdc",
    inputSymbol: "ETH",
    outputSymbol: "USDC",
    inputAmount: 0.5,
    outputAmount: 967,
    amountUsd: 967,
    simulated: true,
    ...overrides,
  }
}

describe("recordSwap — durable swap persistence (#15)", () => {
  test("rejects unauthenticated calls", async () => {
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1"))).rejects.toThrow(/UNAUTHENTICATED/)
  })

  test("rejects a wallet that does not match the authed identity", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1", { wallet: OTHER })),
    ).rejects.toThrow(/WALLET_MISMATCH/)
  })

  test("rejects oversized identifiers before indexed reads or writes", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("x".repeat(100_000)))).rejects.toThrow(
      /intentId must contain 1 to 200 characters/,
    )
    expect(await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })).toHaveLength(0)
  })

  test("records exactly one swap transaction with the token legs", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    await seedPrice(t, "usdc", 1)
    const asUser = t.withIdentity({ subject: WALLET })
    const res = await asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1"))
    expect(res.idempotent).toBe(false)
    expect(res.receipt.status).toBe("success")

    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      status: "success",
      inputSymbol: "ETH",
      outputSymbol: "USDC",
      inputAmount: 0.5,
      outputAmount: 993.5,
      amountUsd: 1000,
    })
  })

  test("is idempotent on a replayed intent (no double record)", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    await seedPrice(t, "usdc", 1)
    const asUser = t.withIdentity({ subject: WALLET })
    const first = await asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1"))
    const replay = await asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1"))
    expect(replay.idempotent).toBe(true)
    expect(replay.transactionId).toBe(first.transactionId)
    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows).toHaveLength(1)
  })

  test("a failed swap persists with a zero output leg (nothing moved)", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    // The real failed path (recordFailure) carries a positive input but a 0 output. This must
    // persist — the durable history explicitly supports failed rows — not be rejected.
    await asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1", { status: "failed", outputAmount: 0 }))
    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows).toHaveLength(1)
    expect(rows[0].status).toBe("failed")
    expect(rows[0].outputAmount).toBe(0)
    expect(rows[0].amountUsd).toBe(0)
  })

  test("rejects a non-positive input amount", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1", { inputAmount: 0 })),
    ).rejects.toThrow(/INVALID_SWAP/)
  })

  test("rejects a successful swap with a zero output amount", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordSwap, swapIntent("s1", { status: "success", outputAmount: 0 })),
    ).rejects.toThrow(/INVALID_SWAP/)
  })

  async function seedPrice(t: ReturnType<typeof convexTest>, symbol: string, priceUsd: number) {
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol,
        llamaId: `test:${symbol}`,
        priceUsd,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      })
    })
  }

  async function seedTradable(t: ReturnType<typeof convexTest>, symbol: string, priceUsd: number, amount: number) {
    await seedPrice(t, symbol, priceUsd)
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET.toLowerCase(),
        assetId: symbol,
        symbol: symbol.toUpperCase(),
        amount,
        valueUsd: amount * priceUsd,
        state: "available",
        updatedAt: Date.now(),
      })
    })
  }

  test("authoritative: recomputes the output from the oracle, ignoring a forged high output", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    await seedPrice(t, "wbtc", 65000)
    const asUser = t.withIdentity({ subject: WALLET })
    // Client forges 1000 WBTC (~$65M) out of a 0.5 ETH input. With both legs priced the server
    // COMPUTES the output (no mint possible): 0.5 ETH=$1000 → 1000/65000 gross, −0.30% fee −0.35% impact.
    const res = await asUser.mutation(
      api.sandbox.transactions.recordSwap,
      swapIntent("mint1", { outputAssetId: "wbtc", outputSymbol: "WBTC", outputAmount: 1000, amountUsd: 967 }),
    )
    expect(res.receipt.status).toBe("success")
    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows[0].outputAmount).toBeCloseTo(0.0152846, 5) // server value, NOT the forged 1000
    expect(rows[0].outputAmount).toBeLessThan(1)
    expect(rows[0].amountUsd).toBeCloseTo(1000, 6) // 0.5 ETH × $2000, not the client's $967
  })

  test("authoritative: recomputes amountUsd from the oracle, ignoring a forged high USD", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "usdc", 1, 10)
    await seedPrice(t, "eth", 2000)
    const asUser = t.withIdentity({ subject: WALLET })
    // Client claims $65M moved from a single USDC input; server recomputes amountUsd = 1×$1 = $1.
    const res = await asUser.mutation(
      api.sandbox.transactions.recordSwap,
      swapIntent("mint2", {
        inputAssetId: "usdc",
        inputSymbol: "USDC",
        inputAmount: 1,
        outputAssetId: "eth",
        outputSymbol: "ETH",
        outputAmount: 1,
        amountUsd: 65_000_000,
      }),
    )
    expect(res.receipt.status).toBe("success")
    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows[0].amountUsd).toBeCloseTo(1, 6) // server value, NOT the forged $65M
  })

  test("authoritative: prices each leg by its asset id, ignoring a forged symbol", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "usdc", 1, 10)
    await seedPrice(t, "wbtc", 65000)
    await seedPrice(t, "eth", 2000)
    const asUser = t.withIdentity({ subject: WALLET })
    // The input leg is USDC but claims to be WBTC. Pricing by the symbol would value 1 USDC at
    // $65,000 and credit ~31 ETH; the server must price the asset it actually moves.
    const res = await asUser.mutation(
      api.sandbox.transactions.recordSwap,
      swapIntent("forged-symbol", {
        inputAssetId: "usdc",
        inputSymbol: "WBTC",
        inputAmount: 1,
        outputAssetId: "eth",
        outputSymbol: "ETH",
        outputAmount: 31,
        amountUsd: 65_000,
      }),
    )
    expect(res.receipt.status).toBe("success")
    const rows = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: WALLET })
    expect(rows[0]).toMatchObject({ inputSymbol: "USDC", outputSymbol: "ETH" })
    expect(rows[0].amountUsd).toBeCloseTo(1, 6)
    expect(rows[0].outputAmount).toBeLessThan(0.001)
    const eth = await t.run((ctx) =>
      ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet_asset", (q) => q.eq("wallet", WALLET.toLowerCase()).eq("assetId", "eth"))
        .first(),
    )
    expect(eth?.amount ?? 0).toBeLessThan(0.001)
  })

  test("rejects a successful swap on a pair the engine cannot route", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "usdc", 1, 10)
    await seedPrice(t, "wsteth", 2300)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordSwap,
        swapIntent("unroutable", {
          inputAssetId: "usdc",
          inputSymbol: "USDC",
          inputAmount: 1,
          outputAssetId: "wsteth",
          outputSymbol: "WSTETH",
          outputAmount: 0.0004,
          amountUsd: 1,
        }),
      ),
    ).rejects.toThrow(/not swap-routable/)
  })

  test("fails closed when either successful swap leg lacks a live oracle price", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordSwap,
        swapIntent("mint3", {
          outputAssetId: "wbtc",
          outputSymbol: "WBTC",
          outputAmount: 1000,
          amountUsd: 65_000_000, // far above 0.5 ETH × $2000
        }),
      ),
    ).rejects.toThrow(/INVALID_SWAP/)
  })

  test("mint guard: allows a swap consistent with the oracle rate", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    await seedPrice(t, "usdc", 1)
    const asUser = t.withIdentity({ subject: WALLET })
    // 0.5 ETH (~$1000) -> ~967 USDC for a claimed $967: within tolerance, must record.
    const res = await asUser.mutation(
      api.sandbox.transactions.recordSwap,
      swapIntent("ok1", { amountUsd: 967, outputAmount: 967 }),
    )
    expect(res.idempotent).toBe(false)
    expect(res.receipt.status).toBe("success")
  })

  test("rejects a successful swap when the oracle row is expired", async () => {
    const t = convexTest(schema, modules)
    await seedTradable(t, "eth", 2000, 1)
    await seedPrice(t, "usdc", 1)
    await t.run(async (ctx) => {
      const eth = await ctx.db
        .query("tokenPrices")
        .withIndex("by_symbol", (q) => q.eq("symbol", "eth"))
        .unique()
      await ctx.db.patch(eth!._id, { updatedAt: Date.now() - 46 * 60 * 1000 })
    })
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(api.sandbox.transactions.recordSwap, swapIntent("expired")),
    ).rejects.toThrow(/current and server-verifiable/)
  })

  test("rejects a successful swap when the authenticated wallet does not hold the input", async () => {
    const t = convexTest(schema, modules)
    await seedPrice(t, "eth", 2000)
    await seedPrice(t, "usdc", 1)
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(api.sandbox.transactions.recordSwap, swapIntent("unfunded")),
    ).rejects.toThrow(/INSUFFICIENT_BALANCE/)
  })
})
