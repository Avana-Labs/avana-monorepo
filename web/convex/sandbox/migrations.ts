import { v } from "convex/values"
import { internalMutation } from "../_generated/server"
import type { MutationCtx } from "../_generated/server"
import type { Doc } from "../_generated/dataModel"
import { SANDBOX_TOKEN_PRICE_USD } from "./onboarding"
import { validatedTokenPriceUsd } from "./oraclePrice"
import { resolveWriteBackPriceUsd } from "./writeBackPrice"

/**
 * One-off, idempotent re-value of seeded MULTIPLY positions after the token-price baseline was
 * corrected downward.
 *
 * A multiply position stores `collateralValueUsd` (intended gross exposure, the INVARIANT) and
 * `collateralAmount` (a TOKEN quantity frozen at claim-time price), and the dashboard re-values
 * exposure as `collateralAmount × currentBaseline`. With the amount frozen at the old high
 * price, exposure re-values DOWN while `debtValueUsd` stays, collapsing equity and pushing
 * seeded positions underwater.
 *
 * FORMULA: collateralAmount = collateralValueUsd / baselinePrice(collateralSymbol), leaving
 * `collateralValueUsd` / `debtValueUsd` untouched so LTV and HF are preserved. Recomputes from
 * the invariant, so a re-run is a no-op. Collateral symbol is the slug's first leg
 * ("wsteth-eth" → wsteth).
 */
function baselinePriceForSlug(marketSlug: string): number {
  const symbol = marketSlug.split("-")[0]?.toLowerCase() ?? ""
  return SANDBOX_TOKEN_PRICE_USD[symbol] ?? 1
}

export const migrateMultiplyCollateralToBaseline = internalMutation({
  args: {
    // Optional single-wallet run (used to validate on the test wallet first).
    wallet: v.optional(v.string()),
    // Pagination for the all-wallets sweep.
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (ctx, { wallet, cursor, batchSize }) => {
    const now = Date.now()
    let scanned = 0
    let migrated = 0

    const applyTo = async (positions: Doc<"positions">[]) => {
      for (const pos of positions) {
        if (pos.product !== "multiply" || pos.status !== "open") continue
        const grossExposureUsd = pos.collateralValueUsd
        if (typeof grossExposureUsd !== "number" || grossExposureUsd <= 0) continue
        scanned++
        const price = baselinePriceForSlug(pos.marketSlug)
        const newAmount = grossExposureUsd / price
        const current = pos.collateralAmount ?? 0
        // Skip if already correct (idempotent / re-runnable).
        if (Math.abs(current - newAmount) <= Math.max(1e-9, newAmount * 1e-9)) continue
        await ctx.db.patch(pos._id, {
          collateralAmount: newAmount,
          lastUpdatedAt: now,
          revision: (pos.revision ?? 0) + 1,
        })
        migrated++
      }
    }

    if (wallet) {
      const rows = await ctx.db
        .query("positions")
        .withIndex("by_wallet_product", (q) => q.eq("wallet", wallet).eq("product", "multiply"))
        .collect()
      await applyTo(rows)
      return { scope: "wallet", wallet, scanned, migrated, isDone: true, continueCursor: null }
    }

    const page = await ctx.db.query("positions").paginate({ cursor: cursor ?? null, numItems: batchSize ?? 200 })
    await applyTo(page.page)
    return { scope: "all", scanned, migrated, isDone: page.isDone, continueCursor: page.continueCursor }
  },
})

/**
 * Backfill: heal product-balance rows that stored USD in the token-quantity `amount` field.
 * Legacy rows persist `amount ≈ valueUsd`, and the dashboard reprices non-LP rows as
 * `amount × livePrice`, inflating Net Value by the token price (a 1 AAVE deposit → +$14k).
 *
 * DETECTION follows the write-back rule (writeBackPrice.ts): an implied unit price
 * (`valueUsd / amount`) of ≈1 while the live oracle price is NOT ≈1 means USD-in-amount, so
 * rewrite `amount = valueUsd / livePrice`. A real (non-$1) implied price is a genuine token
 * quantity and is left alone, which makes this idempotent; `valueUsd` is canonical and never
 * changes. Scoped to lend + multiply — borrow LP collateral is deliberately USD-denominated.
 */
async function healUsdInAmount(
  ctx: MutationCtx,
  row: { assetId: string; symbol: string; amount: number; valueUsd: number },
  now: number,
): Promise<number | null> {
  const { amount, valueUsd } = row
  if (!(valueUsd > 0)) return null
  const impliedPriceUsd = amount > 0 && valueUsd > 0 ? valueUsd / amount : null
  // Only the ≈$1-implied (USD-in-amount) signature is a candidate; a real token price is trusted.
  if (impliedPriceUsd != null && Math.abs(impliedPriceUsd - 1) >= 1e-4) return null
  const oraclePriceUsd = await validatedTokenPriceUsd(ctx, row.assetId ?? row.symbol, now)
  const resolvedPriceUsd = resolveWriteBackPriceUsd(impliedPriceUsd, oraclePriceUsd)
  if (!resolvedPriceUsd || !(resolvedPriceUsd > 0)) return null
  const newAmount = valueUsd / resolvedPriceUsd
  // Idempotent: skip when the amount is already correct.
  if (Math.abs(newAmount - amount) <= Math.max(1e-9, newAmount * 1e-9)) return null
  return newAmount
}

export const backfillProductBalanceAmountUnits = internalMutation({
  args: {
    // Optional single-wallet run (validate on the test wallet first).
    wallet: v.optional(v.string()),
    // All-wallets sweep paginates ONE table per call (positions-style cursor).
    table: v.optional(v.union(v.literal("walletLendBalances"), v.literal("walletMultiplyBalances"))),
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (
    ctx,
    { wallet, table, cursor, batchSize },
  ): Promise<{
    scope: "wallet" | "all"
    wallet?: string
    scanned: number
    migrated: number
    isDone: boolean
    continueCursor: string | null
  }> => {
    const now = Date.now()
    let scanned = 0
    let migrated = 0

    const applyLend = async (rows: Doc<"walletLendBalances">[]) => {
      for (const row of rows) {
        scanned++
        const newAmount = await healUsdInAmount(ctx, row, now)
        if (newAmount == null) continue
        await ctx.db.patch(row._id, { amount: newAmount, updatedAt: now })
        migrated++
      }
    }
    const applyMultiply = async (rows: Doc<"walletMultiplyBalances">[]) => {
      for (const row of rows) {
        scanned++
        const newAmount = await healUsdInAmount(ctx, row, now)
        if (newAmount == null) continue
        await ctx.db.patch(row._id, { amount: newAmount, updatedAt: now })
        migrated++
      }
    }

    if (wallet) {
      await applyLend(
        await ctx.db
          .query("walletLendBalances")
          .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
          .collect(),
      )
      await applyMultiply(
        await ctx.db
          .query("walletMultiplyBalances")
          .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
          .collect(),
      )
      return { scope: "wallet", wallet, scanned, migrated, isDone: true, continueCursor: null }
    }

    const numItems = batchSize ?? 200
    const target = table ?? "walletLendBalances"
    if (target === "walletMultiplyBalances") {
      const page = await ctx.db.query("walletMultiplyBalances").paginate({ cursor: cursor ?? null, numItems })
      await applyMultiply(page.page)
      return { scope: "all", scanned, migrated, isDone: page.isDone, continueCursor: page.continueCursor }
    }
    const page = await ctx.db.query("walletLendBalances").paginate({ cursor: cursor ?? null, numItems })
    await applyLend(page.page)
    return { scope: "all", scanned, migrated, isDone: page.isDone, continueCursor: page.continueCursor }
  },
})

/**
 * Rebase onboarding cost-basis snapshots pinned to a stale static-fixture price. Wallet P/L
 * reads `sandboxProfiles.basketSnapshot[].priceUsdAtClaim` as the per-token basis, and wallets
 * onboarded BEFORE a token gained live oracle coverage stored the SANDBOX_TOKEN_PRICE_USD
 * fallback (LINK $18), so the leg now shows a fake loss against the lower live price.
 *
 * SAFETY: only a leg whose basis still equals the fixture value it would have fallen back to is
 * rebased, so a basis captured from a live claim is never overwritten and genuine P/L is never
 * erased. After a rebase the basis no longer matches that signature, making a re-run a no-op.
 * `amount` is untouched — grant sizing is a separate reseed concern.
 */
const DEFAULT_STALE_BASIS_TOKENS = ["link", "arb", "op", "ldo", "crv", "bal", "aero", "eurc"]

export const rebaseOnboardingStaleBasis = internalMutation({
  args: {
    // Optional single-wallet run (validate on the test wallet first).
    wallet: v.optional(v.string()),
    // Lowercased token ids; defaults to the set that gained live coverage after launch.
    tokens: v.optional(v.array(v.string())),
    // Pagination for the all-wallets sweep.
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (
    ctx,
    { wallet, tokens, cursor, batchSize },
  ): Promise<{
    scope: "wallet" | "all"
    wallet?: string
    scanned: number
    rebased: number
    isDone: boolean
    continueCursor: string | null
  }> => {
    const now = Date.now()
    const targetTokens = new Set((tokens ?? DEFAULT_STALE_BASIS_TOKENS).map((token) => token.toLowerCase()))
    let scanned = 0
    let rebased = 0

    const applyProfile = async (profile: Doc<"sandboxProfiles">) => {
      const basket = profile.basketSnapshot
      if (!basket || basket.length === 0) return
      let changed = false
      const nextBasket = [...basket]
      for (let index = 0; index < nextBasket.length; index++) {
        const leg = nextBasket[index]
        const tokenId = leg.tokenId.toLowerCase()
        if (!targetTokens.has(tokenId)) continue
        scanned++
        const live = await validatedTokenPriceUsd(ctx, tokenId, now)
        if (!live || !(live > 0)) continue
        const fixtureBasis = SANDBOX_TOKEN_PRICE_USD[tokenId] ?? 1
        const isStaleFixture =
          leg.priceUsdAtClaim > 0 && Math.abs(leg.priceUsdAtClaim - fixtureBasis) <= fixtureBasis * 1e-3
        if (!isStaleFixture) continue
        // Already at the live basis (re-run, or the fixture happens to equal live).
        if (Math.abs(live - leg.priceUsdAtClaim) <= leg.priceUsdAtClaim * 1e-6) continue
        nextBasket[index] = { ...leg, priceUsdAtClaim: live }
        changed = true
        rebased++
      }
      if (changed) await ctx.db.patch(profile._id, { basketSnapshot: nextBasket })
    }

    if (wallet) {
      const profile = await ctx.db
        .query("sandboxProfiles")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet.toLowerCase()))
        .unique()
      if (profile) await applyProfile(profile)
      return { scope: "wallet", wallet, scanned, rebased, isDone: true, continueCursor: null }
    }

    const page = await ctx.db.query("sandboxProfiles").paginate({ cursor: cursor ?? null, numItems: batchSize ?? 200 })
    for (const profile of page.page) await applyProfile(profile)
    return { scope: "all", scanned, rebased, isDone: page.isDone, continueCursor: page.continueCursor }
  },
})

/**
 * One-off, idempotent: early onboarding stored the USD value in `walletBorrowBalances.amount`
 * (implied LP price ≈ $1). The borrow conservation check and client hydration read `amount` as an
 * LP token count, so convert those rows at the pool's current LP price (`markets.priceUsd`, the
 * price the server values pledges at). `valueUsd` is untouched, so no balance changes today.
 * Stable pools whose LP price really is ≈ $1 are left alone. `dryRun` reports without writing.
 */
export const backfillBorrowLpTokenAmounts = internalMutation({
  args: {
    dryRun: v.boolean(),
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (ctx, { dryRun, cursor, batchSize }) => {
    const page = await ctx.db
      .query("walletBorrowBalances")
      .paginate({ cursor: cursor ?? null, numItems: batchSize ?? 200 })
    const now = Date.now()
    const planned: Array<{ marketId: string; state: string; valueUsd: number; fromAmount: number; toAmount: number }> =
      []
    for (const row of page.page) {
      if (row.state !== "poolAvailable" && row.state !== "collateral") continue
      if (!row.marketId || !(row.amount > 0) || !(row.valueUsd > 0)) continue
      if (Math.abs(row.valueUsd / row.amount - 1) >= 1e-3) continue
      const marketId = row.marketId
      const market = await ctx.db
        .query("markets")
        .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", marketId))
        .unique()
      const priceUsd = market?.priceUsd
      if (typeof priceUsd !== "number" || !Number.isFinite(priceUsd) || (priceUsd > 0.5 && priceUsd < 2)) continue
      if (!(priceUsd > 0)) continue
      const toAmount = row.valueUsd / priceUsd
      planned.push({ marketId, state: row.state, valueUsd: row.valueUsd, fromAmount: row.amount, toAmount })
      if (!dryRun) await ctx.db.patch(row._id, { amount: toAmount, updatedAt: now })
    }
    return { dryRun, scanned: page.page.length, planned, isDone: page.isDone, continueCursor: page.continueCursor }
  },
})

/**
 * One-off, idempotent follow-up to `backfillBorrowLpTokenAmounts`: an open borrow position whose
 * collateral leg already carries an LP token count (written by the client at its own LP price)
 * is the real count for that pool: the client derived it from the collateral row's USD. Set the
 * collateral row's `amount` to exactly those tokens and the poolAvailable row's at the same claim
 * price (collateral USD ÷ leg tokens). `valueUsd` is untouched.
 */
export const alignBorrowLpTokensToPledgedLegs = internalMutation({
  args: { dryRun: v.boolean() },
  handler: async (ctx, { dryRun }) => {
    const now = Date.now()
    const legs = await ctx.db.query("positionCollateral").collect()
    const planned: Array<{ marketId: string; state: string; fromAmount: number; toAmount: number }> = []
    for (const leg of legs) {
      const principal = BigInt(leg.principalTokenAmount)
      const raw = principal > 0n ? principal : BigInt(leg.collateralShares)
      if (raw < 10n ** 12n) continue
      const position = await ctx.db.get(leg.positionId)
      if (!position || position.product !== "borrow" || position.status !== "open") continue
      const legTokens = Number(raw / 10n ** 6n) / 1e12
      const rows = (
        await ctx.db
          .query("walletBorrowBalances")
          .withIndex("by_wallet", (q) => q.eq("wallet", leg.wallet))
          .collect()
      ).filter((row) => row.marketId === leg.marketSlug)
      const collateralRow = rows.find((row) => row.state === "collateral")
      if (!collateralRow || !(collateralRow.valueUsd > 0) || !(legTokens > 0)) continue
      const claimPriceUsd = collateralRow.valueUsd / legTokens
      for (const row of rows) {
        if (row.state !== "collateral" && row.state !== "poolAvailable") continue
        const toAmount = row === collateralRow ? legTokens : row.valueUsd / claimPriceUsd
        if (Math.abs(toAmount - row.amount) <= Math.max(1e-12, toAmount * 1e-9)) continue
        planned.push({ marketId: leg.marketSlug, state: row.state, fromAmount: row.amount, toAmount })
        if (!dryRun) await ctx.db.patch(row._id, { amount: toAmount, updatedAt: now })
      }
    }
    return { dryRun, planned }
  },
})
