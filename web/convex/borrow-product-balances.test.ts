// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"
import { adjustProductBalanceUsd } from "./sandbox/transactions"
import { COLLATERAL_REPRICE_DRIFT_BAND, resolveCollateralRepriceScale } from "./wallet/productBalances"

const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"
const MARKET = "uni-v3-bluechip-weth-usdc"

describe("borrow product balances", () => {
  test("syncs pledged collateral rows from the absolute position value", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: MARKET,
        poolId: "eth-usdc-lp",
        symbol: "ETH / USDC LP",
        amount: 0,
        valueUsd: 0,
        state: "poolAvailable",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: MARKET,
        poolId: "eth-usdc-lp",
        symbol: "ETH / USDC LP",
        amount: 6.4,
        valueUsd: 800,
        state: "collateral",
        updatedAt: Date.now(),
      })
    })

    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "sync-product-collateral",
      product: "borrow",
      kind: "withdraw",
      marketSlug: MARKET,
      requestedAmountUsd6: "501000000",
      executedAmountUsd6: "501000000",
      amountUsd: 501,
      simulated: true,
      position: {
        status: "open",
        marketSlug: MARKET,
        collateralValueUsd6: "299000000",
        debtValueUsd6: "0",
        collateral: [
          {
            marketSlug: MARKET,
            collateralShares: "299000000",
            principalTokenAmount: "299000000",
            collateralEnabled: true,
            collateralValueUsd6: "299000000",
          },
        ],
        debt: [],
      },
    })

    const balances = await asUser.query(api.wallet.productBalances.listForWallet, { wallet: WALLET })
    const rows = balances.borrow.filter((row) => row.marketId === MARKET)
    expect(rows.find((row) => row.state === "collateral")?.valueUsd).toBe(299)
    expect(rows.find((row) => row.state === "poolAvailable")?.valueUsd).toBe(501)
  })

  test("reprices collateral LP value at the pool's live price, not the frozen claim USD", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    // Claim: 8 LP @ $125 = $1,000 pledged as collateral. Then the pool's live LP price
    // halves (e.g. a collateral token drops ~50%) → the position must revalue to $500,
    // not stay pinned at the frozen $1,000 that would mask liquidation risk.
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: MARKET,
        chainId: 1,
        name: "ETH / USDC",
        symbol: "ETH / USDC",
        maxLtvPct: 76.5,
        priceUsd: 62.5, // live LP price = half of the $125 claim price
        createdAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: MARKET,
        poolId: "eth-usdc-lp",
        symbol: "ETH / USDC LP",
        amount: 8,
        valueUsd: 1000,
        state: "collateral",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("positions", {
        wallet,
        product: "borrow",
        marketSlug: MARKET,
        status: "open",
        collateralValueUsd6: "1000000000",
        debtValueUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
      })
    })

    const asUser = t.withIdentity({ subject: WALLET })
    const balances = await asUser.query(api.wallet.productBalances.listForWallet, { wallet: WALLET })
    const collateral = balances.borrow.find((row) => row.marketId === MARKET && row.state === "collateral")
    expect(collateral?.valueUsd).toBeCloseTo(500, 6)
    expect(collateral?.amount).toBeCloseTo(8, 6) // units unchanged; only the price moved
    expect(collateral?.ltvPct).toBe(76.5)
  })

  // Prod 2026-09-23: the dashboard's Pools table showed the dev wallet's unpledged AURA/WETH and
  // WBTC/ETH LP at a flat $43,750.00; with no collateral row the reprice had no anchor.
  test("reprices an unpledged pool balance at the live LP price", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: MARKET,
        chainId: 1,
        name: "ETH / USDC",
        symbol: "ETH / USDC",
        maxLtvPct: 76.5,
        priceUsd: 150,
        createdAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: MARKET,
        poolId: "eth-usdc-lp",
        symbol: "ETH / USDC LP",
        amount: 8,
        valueUsd: 1000,
        state: "poolAvailable",
        updatedAt: Date.now(),
      })
    })
    const balances = await t
      .withIdentity({ subject: WALLET })
      .query(api.wallet.productBalances.listForWallet, { wallet: WALLET })
    const available = balances.borrow.find((row) => row.marketId === MARKET && row.state === "poolAvailable")
    expect(available?.valueUsd).toBeCloseTo(1200, 6)
    expect(available?.amount).toBeCloseTo(8, 6)
  })

  test("does NOT inflate USD-denominated seeded collateral against a live LP unit price", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    // Regression for the ~$7.1B Net Value bug. Onboarding seeds collateral USD-denominated:
    // pool priceUsd = 1 at claim → amount == valueUsd → claimLp = 1. The oracle later sets the
    // pool's live LP *unit* price to ~$40k (a WBTC/WETH pool). Scaling the frozen $43,750 by
    // liveLp/claimLp = 40000 across those mismatched bases produced ~$1.75B per leg. The frozen
    // claim USD must be preserved when the anchor basis is untrustworthy.
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: MARKET,
        chainId: 1,
        name: "WBTC / WETH",
        symbol: "WBTC / WETH",
        priceUsd: 40_000, // live LP unit price — a different basis than the USD-denominated seed
        createdAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: MARKET,
        poolId: "wbtc-weth-lp",
        symbol: "WBTC / WETH LP",
        amount: 43_750, // seed stored USD as the token amount (pool price = 1) → claimLp = 1
        valueUsd: 43_750,
        state: "collateral",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("positions", {
        wallet,
        product: "borrow",
        marketSlug: MARKET,
        status: "open",
        collateralValueUsd6: "43750000000",
        debtValueUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
      })
    })

    const asUser = t.withIdentity({ subject: WALLET })
    const balances = await asUser.query(api.wallet.productBalances.listForWallet, { wallet: WALLET })
    const collateral = balances.borrow.find((row) => row.marketId === MARKET && row.state === "collateral")
    expect(collateral?.valueUsd).toBeCloseTo(43_750, 6) // frozen claim USD — NOT 43,750 × 40,000
    expect(collateral?.valueUsd).toBeLessThan(1_000_000)
  })
})

describe("multiply product balances", () => {
  test("writes a USD delta as token units when the market price is known", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "multiply",
        slug: "reth-eth",
        chainId: 1,
        name: "RETH / ETH",
        symbol: "RETH",
        priceUsd: 2_386,
        createdAt: 1,
      })
      await adjustProductBalanceUsd(
        ctx,
        "walletMultiplyBalances",
        wallet,
        { marketId: "reth-eth", assetId: "reth", state: "available" },
        "RETH",
        41_666.67,
        1,
        2_386,
      )
    })

    const raw = await t.run(async (ctx) => ctx.db.query("walletMultiplyBalances").collect())
    expect(raw[0]?.amount).toBeCloseTo(41_666.67 / 2_386, 10)
    expect(raw[0]?.valueUsd).toBeCloseTo(41_666.67, 6)
  })

  test("normalizes legacy USD-denominated available buckets to token units", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "multiply",
        slug: "wsteth-eth",
        chainId: 1,
        name: "WSTETH / ETH",
        symbol: "WSTETH",
        priceUsd: 2_982.18,
        createdAt: 1,
      })
      // Legacy close/deleverage writes stored the USD amount as `amount` when
      // no existing token-price sibling was available.
      await ctx.db.insert("walletMultiplyBalances", {
        wallet,
        marketId: "wsteth-eth",
        assetId: "wsteth",
        symbol: "WSTETH",
        amount: 41_666.67,
        valueUsd: 41_666.67,
        state: "available",
        updatedAt: 1,
      })
    })

    const asUser = t.withIdentity({ subject: WALLET })
    const balances = await asUser.query(api.wallet.productBalances.listForWallet, { wallet: WALLET })
    const available = balances.multiply.find((row) => row.marketId === "wsteth-eth" && row.state === "available")

    expect(available?.amount).toBeCloseTo(41_666.67 / 2_982.18, 10)
    expect((available?.amount ?? 0) * 2_982.18).toBeCloseTo(available?.valueUsd ?? 0, 6)
    expect(available?.amount).toBeLessThan(20)
  })
})

describe("resolveCollateralRepriceScale", () => {
  test("applies genuine intra-band drift", () => {
    expect(resolveCollateralRepriceScale(62.5, 125)).toBeCloseTo(0.5, 12) // -50% move
    expect(resolveCollateralRepriceScale(41_000, 40_000)).toBeCloseTo(1.025, 12)
    expect(resolveCollateralRepriceScale(125, 125)).toBe(1)
  })

  test("rejects a claim/live basis mismatch instead of inflating", () => {
    // The $7.1B bug: claimLp = 1 (USD-denominated seed) vs liveLp = 40,000 (LP unit price).
    expect(resolveCollateralRepriceScale(40_000, 1)).toBeUndefined()
    expect(resolveCollateralRepriceScale(1, 40_000)).toBeUndefined() // inverse basis error
    expect(resolveCollateralRepriceScale(COLLATERAL_REPRICE_DRIFT_BAND.max * 2 + 1, 1)).toBeUndefined()
  })

  test("returns undefined for missing or non-positive anchors", () => {
    expect(resolveCollateralRepriceScale(undefined, 125)).toBeUndefined()
    expect(resolveCollateralRepriceScale(125, undefined)).toBeUndefined()
    expect(resolveCollateralRepriceScale(125, 0)).toBeUndefined()
    expect(resolveCollateralRepriceScale(0, 125)).toBeUndefined()
    expect(resolveCollateralRepriceScale(Number.NaN, 125)).toBeUndefined()
  })
})
