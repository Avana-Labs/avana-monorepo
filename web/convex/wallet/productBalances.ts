import { v, type Infer } from "convex/values"
import type { MutationCtx } from "../_generated/server"
import { internalMutation, mutation, query } from "../_generated/server"
import { requireSandboxWallet } from "../sandbox/auth"

/**
 * Plausible-drift band for the live-LP collateral reprice. The reprice is only valid when the
 * claim anchor (`claimLp` = valueUsd/amount) and the live pool price (`liveLp` =
 * markets.priceUsd) share a basis. Onboarding-seeded collateral is USD-denominated (pool
 * priceUsd = 1, so claimLp ≈ 1) while `liveLp` is the LP UNIT price (Σ wᵢ·pᵢ, ~$40k for a
 * WBTC/WETH pool), and scaling across that mismatch inflated Net Value ~40000×. A genuine
 * intra-session move is bounded, so a scale outside this band means basis mismatch: keep the
 * frozen (claim-correct) USD instead.
 */
export const COLLATERAL_REPRICE_DRIFT_BAND = { min: 0.1, max: 10 } as const

export function resolveCollateralRepriceScale(
  liveLp: number | undefined,
  claimLp: number | undefined,
): number | undefined {
  if (liveLp === undefined || claimLp === undefined) return undefined
  if (!(liveLp > 0) || !(claimLp > 0) || !Number.isFinite(liveLp) || !Number.isFinite(claimLp)) return undefined
  const scale = liveLp / claimLp
  if (!Number.isFinite(scale)) return undefined
  if (scale < COLLATERAL_REPRICE_DRIFT_BAND.min || scale > COLLATERAL_REPRICE_DRIFT_BAND.max) return undefined
  return scale
}

const lendState = v.union(v.literal("available"), v.literal("deposited"))
const borrowState = v.union(
  v.literal("poolAvailable"),
  v.literal("collateral"),
  v.literal("debt"),
  v.literal("claimableFees"),
)
const multiplyState = v.union(v.literal("available"), v.literal("collateral"), v.literal("debt"), v.literal("position"))

const lendRow = v.object({
  marketId: v.string(),
  assetId: v.string(),
  symbol: v.string(),
  amount: v.number(),
  valueUsd: v.number(),
  state: lendState,
})

const borrowRow = v.object({
  marketId: v.optional(v.string()),
  assetId: v.optional(v.string()),
  poolId: v.optional(v.string()),
  symbol: v.string(),
  amount: v.number(),
  valueUsd: v.number(),
  state: borrowState,
})

const multiplyRow = v.object({
  marketId: v.optional(v.string()),
  assetId: v.string(),
  symbol: v.string(),
  amount: v.number(),
  valueUsd: v.number(),
  state: multiplyState,
})

const liquidRow = v.object({
  assetId: v.string(),
  symbol: v.string(),
  amount: v.number(),
  valueUsd: v.number(),
  state: v.literal("available"),
})

type ProductBucket = "lend" | "borrow" | "multiply" | "liquid"

async function clearBucket(ctx: MutationCtx, wallet: string, bucket: ProductBucket) {
  const table =
    bucket === "lend"
      ? "walletLendBalances"
      : bucket === "borrow"
        ? "walletBorrowBalances"
        : bucket === "multiply"
          ? "walletMultiplyBalances"
          : "walletLiquidBalances"
  const rows = await ctx.db
    .query(table)
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  for (const row of rows) await ctx.db.delete(row._id)
  return rows.length
}

export async function replaceProductBalanceRows(
  ctx: MutationCtx,
  wallet: string,
  rows: {
    lend?: Array<Infer<typeof lendRow>>
    borrow?: Array<Infer<typeof borrowRow>>
    multiply?: Array<Infer<typeof multiplyRow>>
    liquid?: Array<Infer<typeof liquidRow>>
  },
) {
  const now = Date.now()
  const deleted =
    (rows.lend ? await clearBucket(ctx, wallet, "lend") : 0) +
    (rows.borrow ? await clearBucket(ctx, wallet, "borrow") : 0) +
    (rows.multiply ? await clearBucket(ctx, wallet, "multiply") : 0) +
    (rows.liquid ? await clearBucket(ctx, wallet, "liquid") : 0)

  for (const row of rows.lend ?? []) await ctx.db.insert("walletLendBalances", { ...row, wallet, updatedAt: now })
  for (const row of rows.borrow ?? []) await ctx.db.insert("walletBorrowBalances", { ...row, wallet, updatedAt: now })
  for (const row of rows.multiply ?? [])
    await ctx.db.insert("walletMultiplyBalances", { ...row, wallet, updatedAt: now })
  for (const row of rows.liquid ?? []) await ctx.db.insert("walletLiquidBalances", { ...row, wallet, updatedAt: now })

  return {
    deleted,
    written:
      (rows.lend?.length ?? 0) + (rows.borrow?.length ?? 0) + (rows.multiply?.length ?? 0) + (rows.liquid?.length ?? 0),
  }
}

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const [lend, rawBorrow, rawMultiply, liquid, borrowPositions] = await Promise.all([
      ctx.db
        .query("walletLendBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", authed))
        .collect(),
      ctx.db
        .query("walletBorrowBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", authed))
        .collect(),
      ctx.db
        .query("walletMultiplyBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", authed))
        .collect(),
      ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", authed))
        .collect(),
      ctx.db
        .query("positions")
        .withIndex("by_wallet_product", (q) => q.eq("wallet", authed).eq("product", "borrow"))
        .collect(),
    ])

    const multiplySlugs = [
      ...new Set(rawMultiply.map((row) => row.marketId).filter((slug): slug is string => Boolean(slug))),
    ]
    const multiplyMarkets = await Promise.all(
      multiplySlugs.map((slug) =>
        ctx.db
          .query("markets")
          .withIndex("by_scope_slug", (q) => q.eq("scope", "multiply").eq("slug", slug))
          .unique(),
      ),
    )
    const multiplyPriceBySlug = new Map(
      multiplyMarkets
        .filter((market): market is NonNullable<typeof market> => market !== null)
        .filter(
          (market) => typeof market.priceUsd === "number" && Number.isFinite(market.priceUsd) && market.priceUsd > 0,
        )
        .map((market) => [market.slug, market.priceUsd!] as const),
    )
    // A multiply debt row with no live collateral or position is an ORPHAN: legacy data whose
    // debt was written under a different asset id than the close zeroed. Debt against zero
    // collateral is impossible and its equity already returned to `available`, so counting it
    // double-subtracts. Excluded at READ time so existing orphans self-heal without a reseed.
    const multiplyMarketHasPosition = new Set<string>()
    for (const row of rawMultiply) {
      if ((row.state === "collateral" || row.state === "position") && row.valueUsd > 0 && row.marketId) {
        multiplyMarketHasPosition.add(row.marketId)
      }
    }
    // Available Multiply buckets are USD ledgers plus a display token quantity; normalize at
    // READ time too, so legacy rows written with a $1/token fallback cannot inflate anything.
    const multiply = rawMultiply
      .filter((row) => !(row.state === "debt" && row.marketId != null && !multiplyMarketHasPosition.has(row.marketId)))
      .map((row) => {
        if (row.state !== "available" || !row.marketId) return row
        const priceUsd = multiplyPriceBySlug.get(row.marketId)
        return priceUsd ? { ...row, amount: row.valueUsd / priceUsd } : row
      })

    const pledgedByMarket = new Map<string, { valueUsd: number; updatedAt: number }>()
    for (const position of borrowPositions) {
      if (position.status !== "open") continue
      const legs = await ctx.db
        .query("positionCollateral")
        .withIndex("by_position", (q) => q.eq("positionId", position._id))
        .collect()
      const valueUsd = Math.max(
        0,
        Number(position.collateralValueUsd6 ?? "0") / 1_000_000,
        ...legs.map((leg) => Number(leg.collateralValueUsd6 ?? "0") / 1_000_000),
      )
      const existing = pledgedByMarket.get(position.marketSlug)
      if (!existing || position.lastUpdatedAt >= existing.updatedAt) {
        pledgedByMarket.set(position.marketSlug, { valueUsd, updatedAt: position.lastUpdatedAt })
      }
    }
    const poolTotals = new Map<string, number>()
    for (const row of rawBorrow) {
      if (!row.marketId || (row.state !== "poolAvailable" && row.state !== "collateral")) continue
      poolTotals.set(row.marketId, (poolTotals.get(row.marketId) ?? 0) + row.valueUsd)
    }

    // Reprice borrow-collateral LP at the pool's LIVE LP price, not the frozen claim USD:
    // `markets.priceUsd` (scope "pool") is Σ(weightᵢ × priceᵢ) from refreshPoolLpPrices, the
    // same basis the credit engine and borrow tab use, so a collateral-token fall reconciles
    // across surfaces. The frozen split is scaled by liveLp / claimLp, with claimLp taken from
    // the collateral row (the one row carrying a reliable unit count). Falls back to the frozen
    // basis when the pool has no live price or no anchor, so unpriced pools never zero out.
    const poolSlugs = [...new Set(rawBorrow.map((row) => row.marketId).filter((slug): slug is string => Boolean(slug)))]
    const poolMarkets = await Promise.all(
      poolSlugs.map((slug) =>
        ctx.db
          .query("markets")
          .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", slug))
          .unique(),
      ),
    )
    const collateralPools = await Promise.all(
      poolSlugs.map((slug) =>
        ctx.db
          .query("pools")
          .withIndex("by_slug", (q) => q.eq("slug", slug))
          .unique(),
      ),
    )
    const liveLpBySlug = new Map<string, number>()
    const ltvPctBySlug = new Map<string, number>()
    for (const market of poolMarkets) {
      if (market && typeof market.priceUsd === "number" && Number.isFinite(market.priceUsd) && market.priceUsd > 0) {
        liveLpBySlug.set(market.slug, market.priceUsd)
      }
      if (market && typeof market.maxLtvPct === "number" && Number.isFinite(market.maxLtvPct)) {
        ltvPctBySlug.set(market.slug, market.maxLtvPct)
      }
    }
    for (const pool of collateralPools) {
      if (
        pool &&
        !ltvPctBySlug.has(pool.slug) &&
        typeof pool.maxLtvPct === "number" &&
        Number.isFinite(pool.maxLtvPct)
      ) {
        ltvPctBySlug.set(pool.slug, pool.maxLtvPct)
      }
    }
    const claimLpBySlug = new Map<string, number>()
    for (const row of rawBorrow) {
      if (row.state !== "collateral" || !row.marketId) continue
      if (row.amount > 0 && row.valueUsd > 0) claimLpBySlug.set(row.marketId, row.valueUsd / row.amount)
    }
    // A pool held but not pledged has no collateral row to anchor on; its poolAvailable row carries
    // the same token count, so without this the dashboard showed it at the claim USD forever.
    for (const row of rawBorrow) {
      if (row.state !== "poolAvailable" || !row.marketId || claimLpBySlug.has(row.marketId)) continue
      if (row.amount > 0 && row.valueUsd > 0) claimLpBySlug.set(row.marketId, row.valueUsd / row.amount)
    }

    const borrow = rawBorrow.map((row) => {
      if (!row.marketId || (row.state !== "poolAvailable" && row.state !== "collateral")) {
        return { ...row, ltvPct: row.marketId ? ltvPctBySlug.get(row.marketId) : undefined }
      }
      const pledgedUsd = Math.min(poolTotals.get(row.marketId) ?? 0, pledgedByMarket.get(row.marketId)?.valueUsd ?? 0)
      const frozenValueUsd =
        row.state === "collateral" ? pledgedUsd : Math.max(0, (poolTotals.get(row.marketId) ?? 0) - pledgedUsd)
      const claimPrice = row.amount > 0 && row.valueUsd > 0 ? row.valueUsd / row.amount : 1

      const liveLp = liveLpBySlug.get(row.marketId)
      const claimLp = claimLpBySlug.get(row.marketId)
      const scale = resolveCollateralRepriceScale(liveLp, claimLp)
      if (scale !== undefined && liveLp !== undefined) {
        const valueUsd = frozenValueUsd * scale
        return {
          ...row,
          valueUsd,
          amount: valueUsd / liveLp,
          unitPriceUsd: liveLp,
          ltvPct: ltvPctBySlug.get(row.marketId),
        }
      }
      return {
        ...row,
        valueUsd: frozenValueUsd,
        amount: claimPrice > 0 ? frozenValueUsd / claimPrice : frozenValueUsd,
        ltvPct: ltvPctBySlug.get(row.marketId),
      }
    })

    return {
      lend,
      borrow,
      multiply,
      liquid,
    }
  },
})

export const replaceForWallet = internalMutation({
  args: {
    wallet: v.string(),
    lend: v.optional(v.array(lendRow)),
    borrow: v.optional(v.array(borrowRow)),
    multiply: v.optional(v.array(multiplyRow)),
    liquid: v.optional(v.array(liquidRow)),
  },
  handler: async (ctx, { wallet, lend, borrow, multiply, liquid }) =>
    replaceProductBalanceRows(ctx, wallet, { lend, borrow, multiply, liquid }),
})

export const ensureOpenGateBalances = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const [lend, borrow, multiply, liquid] = await Promise.all([
      ctx.db
        .query("walletLendBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletBorrowBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletMultiplyBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
    ])

    return {
      seeded: false as const,
      initialized: lend.length > 0 || borrow.length > 0 || multiply.length > 0 || liquid.length > 0,
    }
  },
})
