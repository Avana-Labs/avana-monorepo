/**
 * Sandbox liquidation recording. `recordLiquidationPreview` is analytics-only and
 * owner-scoped; `recordLiquidation` atomically updates the victim's debt/collateral and
 * records the transaction, portfolio snapshot and audit row.
 *
 * AUTHORIZATION: unlike the rest of the sandbox (self-only via `requireSandboxWallet`), a
 * liquidation has TWO parties — the caller is the LIQUIDATOR acting on a VICTIM wallet it does
 * not own, so the gate is on the liquidator identity, never the victim.
 */

import { codedError } from "../codedError"
import { v } from "convex/values"
import type { MutationCtx } from "../_generated/server"
import { mutation, query } from "../_generated/server"
import { getAuthedWallet, requireSandboxWallet } from "./auth"
import { tokenNotionalToUsd } from "./collateralUsd"
import { readWalletLiquidBalance } from "../wallet/balances"
import { validatedTokenPriceUsd } from "./oraclePrice"
import {
  adjustProductBalanceUsd,
  appendPortfolioSnapshot,
  appendServerRiskSnapshot,
  applyLedgerDelta,
  applyLiquidAssetDelta,
} from "./transactions"

/** A single liquidation may repay at most this share of outstanding debt (50%). */
const LIQUIDATION_CLOSE_FACTOR_BPS = 5_000
/** Keeper seize premium assumed when the client omits one. */
const DEFAULT_LIQUIDATION_BONUS_BPS = 1_000
/** Hard server-side ceiling on the seize premium (defends a tampered client). */
const MAX_LIQUIDATION_BONUS_BPS = 2_000
const MAX_LIQUIDATIONS_PER_HOUR = 200
const MAX_INTENT_ID_LENGTH = 128
/**
 * Liquidation-threshold basis: LT = explicit `liquidationThresholdPct`, else maxLtv + 10pp
 * capped at 95%, else 85%. Hand-synced with the borrow path's `liquidationThresholdFromMaxLtv`
 * (transactions.ts), which mirrors the client credit engine — Convex cannot import app/lib and
 * the helper is not exported, so the formula is replicated.
 */
const BORROW_FALLBACK_LIQUIDATION_PCT = 85
const LIQUIDATION_THRESHOLD_SPREAD_PCT = 10
const LIQUIDATION_THRESHOLD_CAP_PCT = 95

function requirePositiveUsd6(value: string, field: string) {
  if (value.length === 0 || value.length > 80 || !/^\d+$/.test(value) || BigInt(value) <= 0n) {
    throw codedError(`INVALID_LIQUIDATION: ${field} must be a positive usd6 integer.`)
  }
}

function requireOptionalWad(value: string | null, field: string) {
  if (value !== null && (value.length === 0 || value.length > 80 || !/^\d+$/.test(value))) {
    throw codedError(`INVALID_LIQUIDATION: ${field} must be a non-negative integer WAD.`)
  }
}

/**
 * Revalue a victim collateral leg from shares/principal + the pool/market oracle — NEVER the
 * spoofable client `collateralValueUsd6` — and return its liquidation threshold. Mirrors the
 * borrow path's `serverCollateralValueUsd` so both checks use the same basis.
 */
async function victimCollateralLiquidationValue(
  ctx: MutationCtx,
  row: { marketSlug: string; collateralShares: string; principalTokenAmount: string },
) {
  const principal = BigInt(row.principalTokenAmount)
  const shares = BigInt(row.collateralShares)
  const raw = principal > 0n ? principal : shares
  const [pool, market] = await Promise.all([
    ctx.db
      .query("pools")
      .withIndex("by_slug", (q) => q.eq("slug", row.marketSlug))
      .unique(),
    ctx.db
      .query("markets")
      .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", row.marketSlug))
      .unique(),
  ])
  const priceUsd = pool?.lpTokenPriceUsd ?? market?.priceUsd
  // 18-dec token notional (engine) vs usd6 microdollars (sandbox tests / persistence).
  // Bigint mulDiv for the 18-dec path — see collateral-usd.tokenNotionalToUsd.
  let valueUsd = 0
  if (raw > 0n) {
    valueUsd = raw >= 10n ** 12n ? tokenNotionalToUsd(raw, priceUsd ?? 0) : Number(raw) / 1_000_000
  }
  const thresholdPct =
    pool?.liquidationThresholdPct ??
    (pool?.maxLtvPct != null
      ? Math.min(pool.maxLtvPct + LIQUIDATION_THRESHOLD_SPREAD_PCT, LIQUIDATION_THRESHOLD_CAP_PCT)
      : BORROW_FALLBACK_LIQUIDATION_PCT)
  return { valueUsd, thresholdPct }
}

/**
 * Record a liquidation action (liquidator↔victim). The caller must be the
 * liquidator (the authed wallet); the victim `wallet` is recorded as data.
 */
export const recordLiquidation = mutation({
  args: {
    /** The position owner being liquidated (victim). */
    wallet: v.string(),
    /** The keeper performing the liquidation; must equal the authed wallet. */
    liquidatorWallet: v.string(),
    intentId: v.string(),
    positionId: v.optional(v.id("positions")),
    debtPositionId: v.optional(v.id("positionDebt")),
    marketSlug: v.optional(v.string()),
    repaidUsd6: v.string(),
    seizedCollateralUsd6: v.string(),
    liquidationBonusBps: v.optional(v.number()),
    healthFactorWadBefore: v.union(v.string(), v.null()),
    healthFactorWadAfter: v.union(v.string(), v.null()),
  },
  handler: async (ctx, args) => {
    const liquidator = await getAuthedWallet(ctx)
    if (!liquidator) throw codedError("UNAUTHENTICATED: sign in to record a liquidation.")
    if (liquidator !== args.liquidatorWallet.toLowerCase()) {
      throw codedError("LIQUIDATOR_MISMATCH: the caller must be the liquidator.")
    }
    if (!args.intentId || args.intentId.length > MAX_INTENT_ID_LENGTH) {
      throw codedError("INVALID_LIQUIDATION: intentId is required and must be at most 128 characters.")
    }
    const prior = await ctx.db
      .query("liquidationActions")
      .withIndex("by_liquidator_intent", (q) => q.eq("liquidatorWallet", liquidator).eq("intentId", args.intentId))
      .unique()
    if (prior) return { id: prior._id, hash: prior.syntheticTxHash, idempotent: true }
    if (!args.positionId) {
      throw codedError("INVALID_LIQUIDATION: a victim position is required.")
    }
    requirePositiveUsd6(args.repaidUsd6, "repaidUsd6")
    requirePositiveUsd6(args.seizedCollateralUsd6, "seizedCollateralUsd6")
    requireOptionalWad(args.healthFactorWadBefore, "healthFactorWadBefore")
    requireOptionalWad(args.healthFactorWadAfter, "healthFactorWadAfter")
    if (args.healthFactorWadBefore !== null && BigInt(args.healthFactorWadBefore) >= 1_000_000_000_000_000_000n) {
      throw codedError("INVALID_LIQUIDATION: the victim position is not underwater.")
    }
    const now = Date.now()
    const recent = await ctx.db
      .query("liquidationActions")
      .withIndex("by_liquidator_at", (q) => q.eq("liquidatorWallet", liquidator).gte("at", now - 60 * 60 * 1000))
      .take(MAX_LIQUIDATIONS_PER_HOUR)
    if (recent.length >= MAX_LIQUIDATIONS_PER_HOUR) {
      throw codedError(`RATE_LIMITED: more than ${MAX_LIQUIDATIONS_PER_HOUR} liquidations in the last hour.`)
    }
    const hash = `sim-liquidate-${args.intentId.slice(0, 8)}-${now.toString(36)}`

    {
      const position = await ctx.db.get(args.positionId)
      const victim = args.wallet.toLowerCase()
      if (!position || position.wallet !== victim || position.product !== "borrow") {
        throw codedError("INVALID_LIQUIDATION: position does not belong to the victim wallet.")
      }
      const [collateralRows, debtRows] = await Promise.all([
        ctx.db
          .query("positionCollateral")
          .withIndex("by_position", (q) => q.eq("positionId", args.positionId!))
          .collect(),
        ctx.db
          .query("positionDebt")
          .withIndex("by_position", (q) => q.eq("positionId", args.positionId!))
          .collect(),
      ])
      const debt = args.debtPositionId ? debtRows.find((row) => row._id === args.debtPositionId) : debtRows[0]
      if (!debt) throw codedError("INVALID_LIQUIDATION: debt position was not found.")
      if (args.marketSlug && args.marketSlug !== position.marketSlug) {
        throw codedError("INVALID_LIQUIDATION: market does not match the victim position.")
      }

      // Server-side solvency + sizing gate. `healthFactorWadBefore` is CLIENT-supplied and
      // spoofable (a caller could pass "0" to liquidate a solvent victim), so recompute the
      // victim's HF from stored collateral/debt + the pool oracle — the same basis as
      // `assertBorrowSolvent` — and cap repay/seize by a real close factor × liquidation bonus.
      const debtTotalUsd6 = debtRows.reduce((sum, row) => sum + BigInt(row.principalBorrowedUsd6), 0n)
      if (debtTotalUsd6 <= 0n) {
        throw codedError("INVALID_LIQUIDATION: the victim position has no debt to liquidate.")
      }
      let liquidationValueUsd = 0
      for (const collateral of collateralRows) {
        if (collateral.collateralEnabled === false) continue
        const { valueUsd, thresholdPct } = await victimCollateralLiquidationValue(ctx, collateral)
        liquidationValueUsd += valueUsd * (thresholdPct / 100)
      }
      const debtTotalUsd = Number(debtTotalUsd6) / 1_000_000
      // HF = risk-adjusted collateral / debt; reject a solvent victim (HF ≥ 1) outright.
      if (liquidationValueUsd >= debtTotalUsd) {
        throw codedError("INVALID_LIQUIDATION: the victim position is not underwater.")
      }
      const repay = BigInt(args.repaidUsd6)
      // Close factor: repay at most 50% of the outstanding debt per liquidation.
      if (repay * 10_000n > debtTotalUsd6 * BigInt(LIQUIDATION_CLOSE_FACTOR_BPS)) {
        throw codedError("INVALID_LIQUIDATION: repay exceeds the close factor.")
      }
      // Seize ≤ repay × (1 + liquidation bonus), with the bonus clamped server-side.
      const bonusBps = BigInt(
        Math.min(
          Math.max(0, Math.round(args.liquidationBonusBps ?? DEFAULT_LIQUIDATION_BONUS_BPS)),
          MAX_LIQUIDATION_BONUS_BPS,
        ),
      )
      const maxSeizeUsd6 = (repay * (10_000n + bonusBps)) / 10_000n
      if (BigInt(args.seizedCollateralUsd6) > maxSeizeUsd6) {
        throw codedError("INVALID_LIQUIDATION: seized collateral exceeds the close-factor × bonus cap.")
      }

      // A liquidation is an exchange, not a free write: charge the authenticated keeper in the
      // debt asset at the current oracle price before mutating the victim. The mutation is
      // atomic, so a later failure rolls this back.
      const debtAssetId = debt.baseAssetId.toLowerCase()
      const debtPriceUsd = await validatedTokenPriceUsd(ctx, debtAssetId, now)
      if (debtPriceUsd === null) {
        throw codedError("ORACLE_UNAVAILABLE: current debt-asset price is required for liquidation.")
      }
      const liquidatorBalance = await readWalletLiquidBalance(ctx, liquidator, debtAssetId)
      const repaidUsd = Number(repay) / 1_000_000
      const repaymentTokens = repaidUsd / debtPriceUsd
      if (!liquidatorBalance || liquidatorBalance.amount + 1e-9 < repaymentTokens) {
        throw codedError("INSUFFICIENT_LIQUIDATOR_BALANCE: keeper cannot fund this repayment.")
      }
      await applyLiquidAssetDelta(
        ctx,
        liquidator,
        debtAssetId,
        debtAssetId.toUpperCase(),
        -repaymentTokens,
        now,
        debtPriceUsd,
      )

      const currentPrincipal = BigInt(debt.principalBorrowedUsd6)
      const nextPrincipal = currentPrincipal > repay ? currentPrincipal - repay : 0n
      const currentShares = BigInt(debt.debtSharesUsd6)
      const nextShares = currentPrincipal > 0n ? (currentShares * nextPrincipal) / currentPrincipal : 0n
      await ctx.db.patch(debt._id, {
        principalBorrowedUsd6: nextPrincipal.toString(),
        debtSharesUsd6: nextShares.toString(),
        updatedAt: now,
      })

      let remainingSeize = BigInt(args.seizedCollateralUsd6)
      const seizedByMarket = new Map<string, bigint>()
      for (const collateral of collateralRows) {
        if (remainingSeize === 0n) break
        const currentValue = BigInt(collateral.collateralValueUsd6 ?? "0")
        if (currentValue === 0n) continue
        const seized = currentValue < remainingSeize ? currentValue : remainingSeize
        const nextValue = currentValue - seized
        const currentSharesValue = BigInt(collateral.collateralShares)
        const currentTokenAmount = BigInt(collateral.principalTokenAmount)
        await ctx.db.patch(collateral._id, {
          collateralValueUsd6: nextValue.toString(),
          collateralShares: currentValue > 0n ? ((currentSharesValue * nextValue) / currentValue).toString() : "0",
          principalTokenAmount: currentValue > 0n ? ((currentTokenAmount * nextValue) / currentValue).toString() : "0",
          updatedAt: now,
        })
        seizedByMarket.set(collateral.marketSlug, (seizedByMarket.get(collateral.marketSlug) ?? 0n) + seized)
        remainingSeize -= seized
      }
      if (remainingSeize > 0n) {
        throw codedError("INVALID_LIQUIDATION: seized collateral exceeds the position value.")
      }

      const collateralBefore = collateralRows.reduce((sum, row) => sum + BigInt(row.collateralValueUsd6 ?? "0"), 0n)
      const debtBefore = debtRows.reduce((sum, row) => sum + BigInt(row.principalBorrowedUsd6), 0n)
      const collateralAfter = collateralBefore - BigInt(args.seizedCollateralUsd6)
      const debtAfter = debtBefore - (currentPrincipal - nextPrincipal)
      const closed = collateralAfter <= 0n && debtAfter <= 0n
      await ctx.db.patch(position._id, {
        collateralValueUsd6: (collateralAfter > 0n ? collateralAfter : 0n).toString(),
        debtValueUsd6: (debtAfter > 0n ? debtAfter : 0n).toString(),
        status: closed ? "closed" : "open",
        lastUpdatedAt: now,
        // MUST bump the concurrency token: a liquidation mutates the position outside
        // recordTransaction, so a victim's tab holding the pre-liquidation revision would
        // still pass the STALE_WRITE guard and silently restore the seized collateral and
        // repaid debt. Advancing revision forces that client to reload first.
        revision: (position.revision ?? 0) + 1,
        ...(closed ? { closedAt: now } : {}),
      })

      const seizedUsd = Number(BigInt(args.seizedCollateralUsd6)) / 1_000_000
      const marketSlug = position.marketSlug
      for (const [collateralMarket, seizedUsd6] of seizedByMarket) {
        const [pool, market] = await Promise.all([
          ctx.db
            .query("pools")
            .withIndex("by_slug", (q) => q.eq("slug", collateralMarket))
            .unique(),
          ctx.db
            .query("markets")
            .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", collateralMarket))
            .unique(),
        ])
        const collateralPriceUsd = pool?.lpTokenPriceUsd ?? market?.priceUsd
        if (!collateralPriceUsd || !Number.isFinite(collateralPriceUsd) || collateralPriceUsd <= 0) {
          throw codedError(`ORACLE_UNAVAILABLE: current LP price is required for ${collateralMarket}.`)
        }
        await adjustProductBalanceUsd(
          ctx,
          "walletBorrowBalances",
          liquidator,
          { marketId: collateralMarket, poolId: collateralMarket, state: "poolAvailable" },
          market?.symbol ?? collateralMarket.toUpperCase(),
          Number(seizedUsd6) / 1_000_000,
          now,
          collateralPriceUsd,
        )
      }
      await ctx.db.insert("transactions", {
        wallet: victim,
        intentId: `liquidation:${hash}`,
        product: "borrow",
        kind: "liquidation",
        status: "success",
        marketSlug,
        positionId: position._id,
        requestedAmountUsd6: args.repaidUsd6,
        executedAmountUsd6: args.repaidUsd6,
        amountUsd: repaidUsd,
        healthFactorWadBefore: args.healthFactorWadBefore,
        healthFactorWadAfter: args.healthFactorWadAfter,
        syntheticTxHash: hash,
        simulated: true,
        at: now,
      })
      await applyLedgerDelta(ctx, marketSlug, -repaidUsd, -seizedUsd, now)
      await Promise.all([appendPortfolioSnapshot(ctx, victim, now), appendPortfolioSnapshot(ctx, liquidator, now)])
      await appendServerRiskSnapshot(ctx, victim, now, "liquidation")
    }

    const id = await ctx.db.insert("liquidationActions", {
      wallet: args.wallet.toLowerCase(),
      liquidatorWallet: liquidator,
      intentId: args.intentId,
      positionId: args.positionId,
      debtPositionId: args.debtPositionId,
      marketSlug: args.marketSlug,
      repaidUsd6: args.repaidUsd6,
      seizedCollateralUsd6: args.seizedCollateralUsd6,
      liquidationBonusBps: args.liquidationBonusBps,
      healthFactorWadBefore: args.healthFactorWadBefore,
      healthFactorWadAfter: args.healthFactorWadAfter,
      syntheticTxHash: hash,
      at: now,
    })
    return { id, hash, idempotent: false }
  },
})

/** Liquidations involving the wallet, both as victim and as liquidator. */
export const getLiquidations = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const [asVictim, asLiquidator] = await Promise.all([
      ctx.db
        .query("liquidationActions")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
        .order("desc")
        .take(50),
      ctx.db
        .query("liquidationActions")
        .withIndex("by_liquidator_at", (q) => q.eq("liquidatorWallet", wallet))
        .order("desc")
        .take(50),
    ])
    return { asVictim, asLiquidator }
  },
})
