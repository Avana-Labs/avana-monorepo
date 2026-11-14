/**
 * Wallet-scoped sandbox transaction persistence + reads. Previews stay pure client-side
 * simulation; on execute the adapter calls `recordTransaction`, the SINGLE Convex write
 * path for a balance change. Convex is source of truth for SANDBOX state only.
 *
 * Server-side guarantees, never trusted from the client:
 *   - ownership   — `requireSandboxWallet` derives the wallet from ctx.auth.
 *   - idempotency — a replayed `intentId` returns the existing row (no double-apply).
 *   - rate limit  — at most `MAX_TX_PER_HOUR` per wallet per trailing hour.
 *   - one row     — exactly one `transactions` row per balance-changing action.
 *   - transition  — amounts, product/action compatibility, lend deltas, multiply
 *                   LTV/multiplier and aggregate ledger deltas are all recomputed.
 *
 * Fixed-point amounts cross the wire as decimal strings (see schema encoding contract).
 */

import { codedError } from "../codedError"
import { ConvexError, v, type Infer } from "convex/values"
import type { MutationCtx, QueryCtx } from "../_generated/server"
import { mutation, query } from "../_generated/server"
import { appendLiquidityDelta } from "../liquidity"
import { liquidBalanceView, readWalletLiquidBalance, upsertLiquidWalletBalance } from "../wallet/balances"
import { requireSandboxWallet } from "./auth"
import { computeSwapQuoteMath, getSwapEngineAsset, isSwapPairRoutable } from "./swapQuoteEngine"
import { tokenNotionalToUsd } from "./collateralUsd"
import { deriveClaimAmountUsd } from "./rewards_catalog"
import type { Doc } from "../_generated/dataModel"
import { validatedTokenPriceUsd } from "./oraclePrice"
import { resolveWriteBackPriceUsd } from "./writeBackPrice"
import { canonicalTokenSymbolOrUpper } from "../../app/lib/tokens/canonical-symbol"
import { catalogMultiplyNetApyPct } from "../../app/lib/multiply-system/catalog"
import { requireSandboxWalletForWrite } from "../writeRateLimit"
import {
  assertClose,
  BORROW_FALLBACK_LIQUIDATION_PCT,
  liquidationThresholdFromMaxLtv,
  MAX_MULTIPLIER,
  MAX_POSITION_LEGS,
  numberToUsd6,
  ratioToWad,
  requireBoundedIdentifier,
  requireUnsignedInteger,
  usd6Number,
} from "./transactionInvariants"

type ProductBalanceTable =
  "walletLendBalances" | "walletBorrowBalances" | "walletMultiplyBalances" | "walletLiquidBalances"

/** Apply a successful swap to the canonical liquid and aggregate wallet ledgers. */
async function applySwapBalanceDelta(
  ctx: MutationCtx,
  wallet: string,
  args: {
    inputAssetId: string
    outputAssetId: string
    inputSymbol: string
    outputSymbol: string
    inputAmount: number
    outputAmount: number
    amountUsd: number
  },
  now: number,
) {
  const legs = [
    { assetId: args.inputAssetId, symbol: args.inputSymbol, delta: -args.inputAmount },
    { assetId: args.outputAssetId, symbol: args.outputSymbol, delta: args.outputAmount },
  ] as const

  for (const leg of legs) {
    const liquid = await readWalletLiquidBalance(ctx, wallet, leg.assetId)
    const nextAmount = Math.max(0, (liquid?.amount ?? 0) + leg.delta)
    const priceUsd =
      liquid && liquid.amount > 0
        ? liquid.valueUsd / liquid.amount
        : leg.assetId === args.inputAssetId && args.inputAmount > 0
          ? args.amountUsd / args.inputAmount
          : leg.assetId === args.outputAssetId && args.outputAmount > 0
            ? args.amountUsd / args.outputAmount
            : 1
    const valueUsd = nextAmount * priceUsd
    await upsertLiquidWalletBalance(ctx, {
      wallet,
      assetId: leg.assetId,
      symbol: leg.symbol,
      amount: nextAmount,
      valueUsd,
      updatedAt: now,
    })
  }
}

/** Debit/credit one liquid asset in the canonical wallet ledgers. */
export async function applyLiquidAssetDelta(
  ctx: MutationCtx,
  wallet: string,
  assetId: string,
  symbol: string,
  delta: number,
  now: number,
  priceUsdOverride?: number,
) {
  if (!Number.isFinite(delta) || delta === 0) return
  const liquid = await readWalletLiquidBalance(ctx, wallet, assetId)
  const priceUsd =
    priceUsdOverride && Number.isFinite(priceUsdOverride) && priceUsdOverride > 0
      ? priceUsdOverride
      : liquid && liquid.amount > 0 && liquid.valueUsd > 0
        ? liquid.valueUsd / liquid.amount
        : 1
  const nextAmount = Math.max(0, (liquid?.amount ?? 0) + delta)
  const valueUsd = nextAmount * priceUsd
  await upsertLiquidWalletBalance(ctx, { wallet, assetId, symbol, amount: nextAmount, valueUsd, updatedAt: now })
}

async function upsertProductBalanceValue(
  ctx: MutationCtx,
  table: ProductBalanceTable,
  wallet: string,
  row: {
    marketId?: string
    assetId?: string
    poolId?: string
    symbol: string
    amount: number
    valueUsd: number
    state: string
  },
) {
  const now = Date.now()
  const rows = await ctx.db
    .query(table)
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const existing = rows.find(
    (candidate) =>
      candidate.state === row.state &&
      ("marketId" in candidate ? candidate.marketId : undefined) === row.marketId &&
      ("assetId" in candidate ? candidate.assetId : undefined) === row.assetId &&
      ("poolId" in candidate ? candidate.poolId : undefined) === row.poolId,
  )
  const valueUsd = Math.max(0, row.valueUsd)
  // `amount` is a TOKEN QUANTITY. A real (non-$1) implied unit price is trusted directly, so the
  // healthy path stays oracle-free; an implied price of ≈1 means a caller wrote USD into `amount`,
  // so it is re-checked against the oracle and healed back to a real token quantity.
  const candidateAmount = Math.max(0, row.amount)
  const impliedPriceUsd = candidateAmount > 0 && valueUsd > 0 ? valueUsd / candidateAmount : null
  let amount = candidateAmount
  if (valueUsd > 0 && (impliedPriceUsd == null || Math.abs(impliedPriceUsd - 1) < 1e-4)) {
    const oraclePriceUsd = await validatedTokenPriceUsd(ctx, row.assetId ?? row.symbol, now)
    const resolvedPriceUsd = resolveWriteBackPriceUsd(impliedPriceUsd, oraclePriceUsd)
    if (resolvedPriceUsd && resolvedPriceUsd > 0) amount = valueUsd / resolvedPriceUsd
  }
  const next = { ...row, amount, valueUsd, updatedAt: now }
  if (existing) {
    await ctx.db.patch(existing._id, next as never)
    return
  }
  if (next.amount <= 0 && next.valueUsd <= 0) return
  await ctx.db.insert(table, { ...next, wallet } as never)
}

export async function adjustProductBalanceUsd(
  ctx: MutationCtx,
  table: ProductBalanceTable,
  wallet: string,
  match: { marketId?: string; assetId?: string; poolId?: string; state: string },
  symbol: string,
  deltaUsd: number,
  now: number,
  priceUsdOverride?: number,
) {
  if (!Number.isFinite(deltaUsd) || deltaUsd === 0) return
  const rows = await ctx.db
    .query(table)
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const existing = rows.find(
    (candidate) =>
      candidate.state === match.state &&
      (match.marketId === undefined || ("marketId" in candidate ? candidate.marketId : undefined) === match.marketId) &&
      (match.assetId === undefined || ("assetId" in candidate ? candidate.assetId : undefined) === match.assetId) &&
      (match.poolId === undefined || ("poolId" in candidate ? candidate.poolId : undefined) === match.poolId),
  )
  const sibling =
    existing ??
    rows.find(
      (candidate) =>
        match.marketId !== undefined &&
        ("marketId" in candidate ? candidate.marketId : undefined) === match.marketId &&
        (match.assetId === undefined || ("assetId" in candidate ? candidate.assetId : undefined) === match.assetId),
    )
  const nextValueUsd = Math.max(0, (existing?.valueUsd ?? 0) + deltaUsd)
  // `amount` is a TOKEN QUANTITY and must be derived with a real unit price: prefer an explicit
  // override, then the price implied by an existing/sibling row, then the server oracle. A $1
  // fallback writes the USD figure into `amount`, and the dashboard reprices non-LP rows as
  // `amount × livePrice` — a 1 AAVE ($120.18) deposit then read as $14,443 of Net Value. $1 is
  // only reached for a symbol the oracle does not cover, where amount == valueUsd anyway.
  const impliedPriceUsd =
    existing && existing.amount > 0 && existing.valueUsd > 0
      ? existing.valueUsd / existing.amount
      : sibling && sibling.amount > 0 && sibling.valueUsd > 0
        ? sibling.valueUsd / sibling.amount
        : null
  let resolvedPriceUsd: number | null
  if (priceUsdOverride && Number.isFinite(priceUsdOverride) && priceUsdOverride > 0) {
    resolvedPriceUsd = priceUsdOverride
  } else if (impliedPriceUsd != null && impliedPriceUsd > 0 && Math.abs(impliedPriceUsd - 1) >= 1e-4) {
    // A real (non-$1) unit price from the row's own history; trusted without an oracle read.
    resolvedPriceUsd = impliedPriceUsd
  } else {
    // New row, or a USD-in-amount row (implied ≈ 1): consult the oracle so a corrupt `amount`
    // heals instead of re-deriving valueUsd / 1 = valueUsd forever.
    const oraclePriceUsd = await validatedTokenPriceUsd(ctx, match.assetId ?? symbol, now)
    resolvedPriceUsd = resolveWriteBackPriceUsd(impliedPriceUsd, oraclePriceUsd)
  }
  const priceUsd = resolvedPriceUsd && resolvedPriceUsd > 0 ? resolvedPriceUsd : 1
  const nextAmount = priceUsd > 0 ? nextValueUsd / priceUsd : nextValueUsd
  if (existing) {
    await ctx.db.patch(existing._id, { amount: nextAmount, valueUsd: nextValueUsd, updatedAt: now })
    return
  }
  if (nextValueUsd <= 0) return
  await ctx.db.insert(table, {
    wallet,
    marketId: match.marketId,
    assetId: match.assetId,
    poolId: match.poolId ?? (sibling && "poolId" in sibling ? sibling.poolId : undefined),
    symbol: sibling?.symbol ?? symbol,
    amount: nextAmount,
    valueUsd: nextValueUsd,
    state: match.state,
    updatedAt: now,
  } as never)
}

async function syncBorrowProductCollateralRows(
  ctx: MutationCtx,
  wallet: string,
  marketSlug: string,
  position: Infer<typeof positionPayload>,
  _now: number,
) {
  const rows = await ctx.db
    .query("walletBorrowBalances")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const related = rows.filter((row) => row.marketId === marketSlug)
  const poolRows = related.filter((row) => row.state === "poolAvailable" || row.state === "collateral")
  const existingAvailable = poolRows.find((row) => row.state === "poolAvailable")
  const existingCollateral = poolRows.find((row) => row.state === "collateral")
  const sibling = existingAvailable ?? existingCollateral ?? poolRows[0]
  const collateralFromLegs = (position.collateral ?? []).reduce(
    (sum, leg) => sum + (leg.collateralValueUsd6 ? usd6Number(leg.collateralValueUsd6) : 0),
    0,
  )
  const pledgedUsd =
    position.status === "closed"
      ? 0
      : Math.max(
          0,
          position.collateralValueUsd ??
            (position.collateralValueUsd6 ? usd6Number(position.collateralValueUsd6) : collateralFromLegs),
        )
  const totalPoolUsd = Math.max(
    pledgedUsd,
    poolRows.reduce((sum, row) => sum + row.valueUsd, 0),
  )
  const availableUsd = Math.max(0, totalPoolUsd - pledgedUsd)
  const poolId = sibling?.poolId ?? marketSlug
  const symbol = sibling?.symbol ?? canonicalTokenSymbolOrUpper(marketSlug)
  const [pool, market] = sibling
    ? [null, null]
    : await Promise.all([
        ctx.db
          .query("pools")
          .withIndex("by_slug", (q) => q.eq("slug", marketSlug))
          .unique(),
        ctx.db
          .query("markets")
          .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", marketSlug))
          .unique(),
      ])
  const priceUsd =
    sibling && sibling.amount > 0 && sibling.valueUsd > 0
      ? sibling.valueUsd / sibling.amount
      : (pool?.lpTokenPriceUsd ?? market?.priceUsd ?? 1)

  // Keep `amount` an exact LP token count: the pledged legs carry it, and the conservation check
  // compares tokens. Deriving it from the client's USD at the claim price drifted with every
  // price move. USD stays on the claim basis so the live reprice (liveLp / claimLp) still applies.
  const legTokens = (position.collateral ?? []).reduce<number | undefined>((sum, leg) => {
    const tokens = collateralLegTokenAmount(leg)
    return sum === undefined || tokens === undefined ? undefined : sum + tokens
  }, 0)
  const ownedTokens =
    poolRows.length > 0 && (await borrowRowsHoldLpTokens(ctx, marketSlug, poolRows))
      ? poolRows.reduce((sum, row) => sum + row.amount, 0)
      : undefined
  const pledgedTokens = position.status === "closed" ? 0 : legTokens
  const tokenSplit =
    pledgedTokens !== undefined && ownedTokens !== undefined && (position.collateral ?? []).length > 0
      ? { pledged: Math.min(pledgedTokens, ownedTokens), available: Math.max(0, ownedTokens - pledgedTokens) }
      : undefined

  await upsertProductBalanceValue(ctx, "walletBorrowBalances", wallet, {
    marketId: marketSlug,
    poolId,
    symbol,
    amount: tokenSplit ? tokenSplit.available : priceUsd > 0 ? availableUsd / priceUsd : availableUsd,
    valueUsd: tokenSplit ? tokenSplit.available * priceUsd : availableUsd,
    state: "poolAvailable",
  })
  await upsertProductBalanceValue(ctx, "walletBorrowBalances", wallet, {
    marketId: marketSlug,
    poolId,
    symbol,
    amount: tokenSplit ? tokenSplit.pledged : priceUsd > 0 ? pledgedUsd / priceUsd : pledgedUsd,
    valueUsd: tokenSplit ? tokenSplit.pledged * priceUsd : pledgedUsd,
    state: "collateral",
  })
}

function liquidAssetIdFromArgs(assetId?: string, marketSlug?: string): string {
  if (assetId) {
    const base = assetId.includes(":") ? assetId.split(":").pop() : assetId
    if (base) return base.toLowerCase()
  }
  if (marketSlug) {
    const parts = marketSlug.toLowerCase().split(/[-_:]/)
    const stable = parts.find((part) => part === "usdc" || part === "usdt" || part === "dai")
    if (stable) return stable
    const last = parts.at(-1)
    if (last) return last
  }
  return "usdc"
}

function inferDebtAssetIdFromMarketSlug(
  marketSlug: string | undefined,
  debtRows: Array<{ assetId: string; baseAssetId: string }>,
) {
  const marketToken = marketSlug?.split("-").at(-1)?.toLowerCase()
  if (!marketToken) return undefined
  return debtRows.find(
    (debt) => debt.baseAssetId.toLowerCase() === marketToken || debt.assetId.toLowerCase().endsWith(`:${marketToken}`),
  )?.assetId
}

/** Hourly per-wallet transaction cap (anti-abuse). Exported for tests. */
export const MAX_TX_PER_HOUR = 200
const PORTFOLIO_HISTORY_INTERVAL_MS = 60 * 60 * 1000
const MAX_PORTFOLIO_HISTORY_ROWS = 365
const MAX_RISK_HISTORY_ROWS = 365

/** Global multiply leverage ceiling, mirrors MULTIPLY_ACTION_MAX_LEVERAGE (client slider). */

/** Liquidation threshold (%) assumed when a pledged pool has none recorded AND no maxLtv to
 *  derive one from. Conservative. */

/**
 * Liquidation threshold for a pool with no explicit `liquidationThresholdPct`:
 * LT = maxLtv + 10pp, capped at 95%. MUST stay in lockstep with the client engine's
 * `estimateLiquidationThresholdWad` (borrow-system/mock.ts) — Convex cannot import app/, so
 * this is hand-synced. Using the raw maxLtv understates liquidation value and rejects borrows
 * the client preview showed as solvent, breaking confirm==persist parity.
 */
/** Optional position upsert payload carried by a transaction. */
const positionPayload = v.object({
  status: v.union(v.literal("open"), v.literal("closed")),
  marketSlug: v.optional(v.string()),
  spokeId: v.optional(v.string()),
  assetId: v.optional(v.string()),
  collateralValueUsd6: v.optional(v.string()),
  debtValueUsd6: v.optional(v.string()),
  suppliedUsd6: v.optional(v.string()),
  earnedUsd6: v.optional(v.string()),
  supplyApyPct: v.optional(v.number()),
  collateralAmount: v.optional(v.number()),
  collateralValueUsd: v.optional(v.number()),
  debtValueUsd: v.optional(v.number()),
  multiplier: v.optional(v.number()),
  ltv: v.optional(v.number()),
  healthFactor: v.optional(v.union(v.number(), v.literal("infinity"))),
  liquidationPrice: v.optional(v.union(v.number(), v.null())),
  netApyPct: v.optional(v.number()),
  collateral: v.optional(
    v.array(
      v.object({
        marketSlug: v.string(),
        collateralShares: v.string(),
        principalTokenAmount: v.string(),
        collateralEnabled: v.boolean(),
        collateralValueUsd6: v.optional(v.string()),
      }),
    ),
  ),
  debt: v.optional(
    v.array(
      v.object({
        assetId: v.string(),
        baseAssetId: v.string(),
        spokeId: v.optional(v.string()),
        marketSlug: v.optional(v.string()),
        debtSharesUsd6: v.string(),
        debtIndexRay: v.string(),
        borrowRateWad: v.string(),
        principalBorrowedUsd6: v.string(),
      }),
    ),
  ),
})

function validatePositionPayload(position: Infer<typeof positionPayload>) {
  if ((position.collateral?.length ?? 0) > MAX_POSITION_LEGS || (position.debt?.length ?? 0) > MAX_POSITION_LEGS) {
    throw codedError(`INVALID_POSITION: a position may contain at most ${MAX_POSITION_LEGS} collateral and debt legs.`)
  }
  for (const [field, value] of Object.entries({
    collateralValueUsd6: position.collateralValueUsd6,
    debtValueUsd6: position.debtValueUsd6,
    suppliedUsd6: position.suppliedUsd6,
    earnedUsd6: position.earnedUsd6,
  })) {
    if (value !== undefined) requireUnsignedInteger(value, field)
  }
  for (const collateral of position.collateral ?? []) {
    requireUnsignedInteger(collateral.collateralShares, "collateralShares")
    requireUnsignedInteger(collateral.principalTokenAmount, "principalTokenAmount")
    if (collateral.collateralValueUsd6 !== undefined) {
      requireUnsignedInteger(collateral.collateralValueUsd6, "collateralValueUsd6")
    }
  }
  for (const debt of position.debt ?? []) {
    requireUnsignedInteger(debt.debtSharesUsd6, "debtSharesUsd6")
    requireUnsignedInteger(debt.debtIndexRay, "debtIndexRay")
    requireUnsignedInteger(debt.borrowRateWad, "borrowRateWad")
    requireUnsignedInteger(debt.principalBorrowedUsd6, "principalBorrowedUsd6")
  }
}

function validateTransactionTransition(
  args: {
    product: "borrow" | "lend" | "multiply"
    kind: string
    requestedAmountUsd6: string
    executedAmountUsd6: string
    amountUsd: number
    position?: Infer<typeof positionPayload>
  },
  existing?: Doc<"positions">,
  // Read pre-transaction lend supplied from the product-balance ledger (walletLendBalances), the
  // same source the client computes against — the `positions` row can lag it after a desync and
  // trip the transition check on a legitimate deposit. The following write re-syncs both.
  lendSuppliedBeforeUsd?: number,
) {
  requireUnsignedInteger(args.requestedAmountUsd6, "requestedAmountUsd6")
  requireUnsignedInteger(args.executedAmountUsd6, "executedAmountUsd6")
  const requested = BigInt(args.requestedAmountUsd6)
  const executed = BigInt(args.executedAmountUsd6)
  if (requested > 0n && executed > requested) {
    throw codedError("INVALID_TRANSITION: executed amount exceeds the requested amount.")
  }
  assertClose(args.amountUsd, Number(executed) / 1_000_000, "amountUsd")

  const allowedKinds = {
    borrow: new Set(["deposit", "withdraw", "borrow", "repay", "claim"]),
    lend: new Set(["deposit", "withdraw", "claim"]),
    // "close" carries an explicit zeroed position payload (see multiplyResultToRecordArgs) so
    // the server runs its position-close branch instead of leaving a resurrecting "open" row.
    multiply: new Set(["multiply", "deleverage", "close"]),
  }
  if (!allowedKinds[args.product].has(args.kind)) {
    throw codedError(`INVALID_TRANSITION: ${args.kind} is not valid for ${args.product}.`)
  }

  if (!args.position) return
  if (args.product === "lend" && args.kind !== "claim") {
    const before = lendSuppliedBeforeUsd ?? usd6Number(existing?.suppliedUsd6)
    const after = usd6Number(args.position.suppliedUsd6)
    const expected = args.kind === "deposit" ? before + args.amountUsd : before - args.amountUsd
    // Client and server price the tokens from the same oracle but may read it moments apart, and
    // interest accrues client-side; the ledger itself is written from the server's token math.
    const tolerance = Math.max(0.02, before * 0.01)
    if (!Number.isFinite(after) || Math.abs(after - Math.max(0, expected)) > tolerance) {
      throw codedError(
        `INVALID_TRANSITION: lend supplied balance does not match the server recomputation ` +
          `(before=${before}, after=${after}, amount=${args.amountUsd}, expected=${Math.max(0, expected)}).`,
      )
    }
  }
  if (args.product === "multiply") {
    const collateral = args.position.collateralValueUsd ?? 0
    const debt = args.position.debtValueUsd ?? 0
    if (collateral < 0 || debt < 0 || debt > collateral) {
      throw codedError("INVALID_TRANSITION: multiply collateral and debt are inconsistent.")
    }
    const equity = collateral - debt
    const expectedMultiplier = equity > 0 ? collateral / equity : 1
    const expectedLtv = collateral > 0 ? debt / collateral : 0
    assertClose(args.position.multiplier ?? 1, expectedMultiplier, "multiply multiplier", 0.0001)
    assertClose(args.position.ltv ?? 0, expectedLtv, "multiply LTV", 0.0001)
    // Opening/adding ("multiply") never shrinks an open loop; unwinding goes through deleverage or
    // close. A client that missed the persisted loop sent a fresh position and the write replaced
    // it (prod: a $83,333 AAVE/GHO loop became a $207 one).
    if (
      args.kind === "multiply" &&
      existing?.status === "open" &&
      (existing.collateralAmount ?? 0) > 0 &&
      (args.position.collateralAmount ?? 0) < (existing.collateralAmount ?? 0) * (1 - 1e-6)
    ) {
      throw codedError("STALE_WRITE: this Multiply position changed; reload it before adding to it.")
    }
    // Leverage caps must be enforced here, not just by the UI slider: a tampered client can
    // submit an internally-consistent position above MULTIPLY_ACTION_MAX_LEVERAGE.
    if ((args.position.multiplier ?? 1) > MAX_MULTIPLIER + 0.01) {
      throw codedError("INVALID_TRANSITION: multiplier exceeds the protocol maximum.")
    }
  }
}

/**
 * Revalue a collateral leg from shares/principal + server oracle — NEVER from the
 * client-supplied `collateralValueUsd6`, which is display-only and spoofable. Sandbox writes
 * store usd6 microdollars in shares/principal; real engine positions store 18-decimal LP
 * token amounts, converted via `pools.lpTokenPriceUsd` / `markets.priceUsd`.
 */
async function serverCollateralValueUsd(
  ctx: MutationCtx,
  row: { marketSlug: string; collateralShares: string; principalTokenAmount: string },
) {
  const principal = BigInt(row.principalTokenAmount)
  const shares = BigInt(row.collateralShares)
  const raw = principal > 0n ? principal : shares
  if (raw <= 0n) {
    throw codedError(`INVALID_TRANSITION: collateral ${row.marketSlug} has no server-verifiable value.`)
  }

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
  const valueUsd =
    raw >= 10n ** 12n
      ? priceUsd && priceUsd > 0
        ? tokenNotionalToUsd(raw, priceUsd)
        : (() => {
            throw codedError(`INVALID_TRANSITION: collateral ${row.marketSlug} has no server-verifiable value.`)
          })()
      : Number(raw) / 1_000_000

  if (!(valueUsd > 0)) {
    throw codedError(`INVALID_TRANSITION: collateral ${row.marketSlug} has no server-verifiable value.`)
  }
  return { valueUsd, pool }
}

/**
 * Rethrows a coded business error (`CODE: detail`) as a ConvexError. Convex replaces a plain
 * Error's message with "Server Error" in production, so the action page could only show the raw
 * "[CONVEX M(...)] Server Error" string. The code and detail reach the client in `error.data`,
 * where humanizeBlockedReason maps them to plain copy. Writes are rolled back either way.
 */
async function withClientErrorCode<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (error) {
    const message = error instanceof Error ? error.message : ""
    const code = /^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+):/.exec(message)?.[1]
    if (!code || error instanceof ConvexError) throw error
    throw new ConvexError({ code, message })
  }
}

/**
 * Server-side borrow solvency re-derivation. The Credit Engine runs in the browser, so the
 * server must independently confirm no borrow/withdraw persists an underwater (HF < 1) or
 * unbacked position — otherwise a tampered client could record arbitrary debt against zero
 * collateral. Collateral USD comes from shares/principal + oracle and pool liquidation
 * thresholds, never from a client-supplied HF or collateralValueUsd6.
 */
async function assertBorrowSolvent(
  ctx: MutationCtx,
  args: { product: "borrow" | "lend" | "multiply"; kind: string; position?: Infer<typeof positionPayload> },
) {
  if (args.product !== "borrow" || !args.position) return
  const debtUsd = usd6Number(args.position.debtValueUsd6)
  if (debtUsd <= 0) return // no debt → nothing to back

  const collateralRows = (args.position.collateral ?? []).filter((row) => row.collateralEnabled !== false)
  if (collateralRows.length === 0) {
    throw codedError("INVALID_TRANSITION: borrow debt has no backing collateral.")
  }

  let liquidationValueUsd = 0
  for (const row of collateralRows) {
    const { valueUsd, pool } = await serverCollateralValueUsd(ctx, row)
    // Must match the client engine's HF basis: explicit LT, else maxLtv + 10pp (capped 95%).
    // The raw maxLtv is the borrow-capacity collateral factor and understates liquidation value.
    const thresholdPct =
      pool?.liquidationThresholdPct ??
      (pool?.maxLtvPct != null ? liquidationThresholdFromMaxLtv(pool.maxLtvPct) : BORROW_FALLBACK_LIQUIDATION_PCT)
    liquidationValueUsd += valueUsd * (thresholdPct / 100)
  }

  if (debtUsd > liquidationValueUsd + 0.01) {
    throw codedError("INVALID_TRANSITION: borrow position would be undercollateralized (health factor < 1).")
  }
}

/** Derive risk history from persisted positions and server market parameters. */
export async function appendServerRiskSnapshot(ctx: MutationCtx, wallet: string, now: number, trigger: string) {
  const positions = await ctx.db
    .query("positions")
    .withIndex("by_wallet_product", (q) => q.eq("wallet", wallet).eq("product", "borrow"))
    .collect()
  const open = positions.filter((position) => position.status === "open")
  let collateralValueUsd = 0
  let borrowCapacityUsd = 0
  let liquidationValueUsd = 0
  let totalBorrowedUsd = 0
  const spokeTotals = new Map<
    string,
    { borrowCapacityUsd: number; liquidationValueUsd: number; totalBorrowedUsd: number }
  >()

  for (const position of open) {
    const [collateralRows, debtRows] = await Promise.all([
      ctx.db
        .query("positionCollateral")
        .withIndex("by_position", (q) => q.eq("positionId", position._id))
        .collect(),
      ctx.db
        .query("positionDebt")
        .withIndex("by_position", (q) => q.eq("positionId", position._id))
        .collect(),
    ])
    const spokeId = position.spokeId ?? position.marketSlug
    const spoke = spokeTotals.get(spokeId) ?? { borrowCapacityUsd: 0, liquidationValueUsd: 0, totalBorrowedUsd: 0 }
    for (const collateral of collateralRows) {
      if (collateral.collateralEnabled === false) continue
      let valueUsd: number
      let pool: Awaited<ReturnType<typeof serverCollateralValueUsd>>["pool"]
      if (BigInt(collateral.principalTokenAmount) > 0n || BigInt(collateral.collateralShares) > 0n) {
        const valued = await serverCollateralValueUsd(ctx, collateral)
        valueUsd = valued.valueUsd
        pool = valued.pool
      } else {
        valueUsd = usd6Number(collateral.collateralValueUsd6)
        pool = await ctx.db
          .query("pools")
          .withIndex("by_slug", (q) => q.eq("slug", collateral.marketSlug))
          .unique()
      }
      const collateralFactorPct = pool?.maxLtvPct ?? 75
      const liquidationThresholdPct =
        pool?.liquidationThresholdPct ?? liquidationThresholdFromMaxLtv(collateralFactorPct)
      collateralValueUsd += valueUsd
      borrowCapacityUsd += valueUsd * (collateralFactorPct / 100)
      liquidationValueUsd += valueUsd * (liquidationThresholdPct / 100)
      spoke.borrowCapacityUsd += valueUsd * (collateralFactorPct / 100)
      spoke.liquidationValueUsd += valueUsd * (liquidationThresholdPct / 100)
    }
    const positionDebtUsd = debtRows.reduce((sum, debt) => sum + usd6Number(debt.principalBorrowedUsd6), 0)
    totalBorrowedUsd += positionDebtUsd
    spoke.totalBorrowedUsd += positionDebtUsd
    spokeTotals.set(spokeId, spoke)
  }

  const healthFactor = totalBorrowedUsd > 0 ? liquidationValueUsd / totalBorrowedUsd : null
  const id = await ctx.db.insert("riskSnapshots", {
    wallet,
    collateralValueUsd6: numberToUsd6(collateralValueUsd),
    borrowCapacityUsd6: numberToUsd6(borrowCapacityUsd),
    availableBorrowCapacityUsd6: numberToUsd6(Math.max(0, borrowCapacityUsd - totalBorrowedUsd)),
    totalBorrowedUsd6: numberToUsd6(totalBorrowedUsd),
    currentLtvWad: ratioToWad(collateralValueUsd > 0 ? totalBorrowedUsd / collateralValueUsd : 0)!,
    healthFactorWad: ratioToWad(healthFactor),
    spokes: [...spokeTotals.entries()].map(([spokeId, spoke]) => ({
      spokeId,
      availableCreditUsd6: numberToUsd6(Math.max(0, spoke.borrowCapacityUsd - spoke.totalBorrowedUsd)),
      totalBorrowedUsd6: numberToUsd6(spoke.totalBorrowedUsd),
      liquidationBufferUsd6: numberToUsd6(Math.max(0, spoke.liquidationValueUsd - spoke.totalBorrowedUsd)),
      healthFactorWad: ratioToWad(
        spoke.totalBorrowedUsd > 0 ? spoke.liquidationValueUsd / spoke.totalBorrowedUsd : null,
      ),
    })),
    trigger: trigger.slice(0, 100),
    at: now,
  })
  const rows = await ctx.db
    .query("riskSnapshots")
    .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
    .order("desc")
    .take(MAX_RISK_HISTORY_ROWS + 25)
  for (const stale of rows.slice(MAX_RISK_HISTORY_ROWS)) await ctx.db.delete(stale._id)
  return id
}

/** A client cannot create more pledged LP collateral than this wallet owns in that pool. */
async function assertBorrowCollateralConserved(
  ctx: MutationCtx,
  wallet: string,
  args: { product: "borrow" | "lend" | "multiply"; position?: Infer<typeof positionPayload> },
) {
  if (args.product !== "borrow" || !args.position || args.position.status === "closed") return
  const legs = args.position.collateral ?? []
  const nextByMarket = new Map<string, { usd: number; tokens: number | undefined }>()
  for (const leg of legs) {
    const { valueUsd } = await serverCollateralValueUsd(ctx, leg)
    const tokens = collateralLegTokenAmount(leg)
    const current = nextByMarket.get(leg.marketSlug) ?? { usd: 0, tokens: 0 }
    nextByMarket.set(leg.marketSlug, {
      usd: current.usd + valueUsd,
      tokens: current.tokens === undefined || tokens === undefined ? undefined : current.tokens + tokens,
    })
  }
  const rows = await ctx.db
    .query("walletBorrowBalances")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  for (const [marketSlug, next] of nextByMarket) {
    const owned = rows.filter(
      (row) => row.marketId === marketSlug && (row.state === "poolAvailable" || row.state === "collateral"),
    )
    const ownedUsd = owned.reduce((sum, row) => sum + row.valueUsd, 0)
    // LP tokens are the conserved quantity: the stored USD is frozen at claim while the pledge is
    // valued at the live LP price, so a USD comparison rejected every borrow and repay once the
    // pool price rose. Rows still holding USD in `amount` (early onboarding) keep the USD check.
    const ownedTokens = (await borrowRowsHoldLpTokens(ctx, marketSlug, owned))
      ? owned.reduce((sum, row) => sum + row.amount, 0)
      : undefined
    const exceeds =
      next.tokens !== undefined && ownedTokens !== undefined
        ? next.tokens > ownedTokens * (1 + 1e-9) + 1e-12
        : next.usd > ownedUsd + 0.02
    if (exceeds) {
      throw codedError("INSUFFICIENT_COLLATERAL_BALANCE: pledged collateral exceeds this wallet's pool balance.")
    }
  }
}

/** LP token quantity of an 18-decimal collateral leg; undefined for the legacy usd6 leg shape. */
function collateralLegTokenAmount(leg: { collateralShares: string; principalTokenAmount: string }) {
  const principal = BigInt(leg.principalTokenAmount)
  const raw = principal > 0n ? principal : BigInt(leg.collateralShares)
  if (raw < 10n ** 12n) return undefined
  return Number(raw / 10n ** 6n) / 1e12
}

/**
 * Whether these rows store an LP token count in `amount`. Early onboarding wrote the USD value
 * there (implied unit price ≈ $1); that is only a token count when the pool's LP price is ≈ $1.
 */
async function borrowRowsHoldLpTokens(
  ctx: MutationCtx,
  marketSlug: string,
  rows: ReadonlyArray<{ amount: number; valueUsd: number }>,
) {
  const priced = rows.filter((row) => row.amount > 0 && row.valueUsd > 0)
  if (priced.length === 0) return rows.every((row) => row.amount === 0 && row.valueUsd === 0)
  if (priced.every((row) => Math.abs(row.valueUsd / row.amount - 1) > 1e-3)) return true
  const market = await ctx.db
    .query("markets")
    .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", marketSlug))
    .unique()
  return typeof market?.priceUsd === "number" && market.priceUsd > 0.5 && market.priceUsd < 2
}

/**
 * Equity of the stored Multiply position at the live collateral price. The client reprices the
 * position at the live oracle price before computing the next one (1344e827), so diffing that
 * against the collateralValueUsd stored at the last write booked every price move as user
 * funding: a close credited the equity from the last write instead of what the position was
 * worth, and a deleverage after a gain demanded a top-up. Falls back to the stored equity when
 * the payload does not name the collateral or it has no current oracle price.
 */
/**
 * The multiply market's collateral asset id from the canonical `markets` row (its `symbol` is the
 * collateral token). The client also sends a collateral `assetId`; it must match, because prior
 * equity is repriced from it and a substituted higher-priced asset (close a WETH loop naming
 * WBTC) would inflate the equity credited back to the wallet. Returns undefined when the market
 * row is missing, which leaves prior equity at its stored value.
 */
async function canonicalMultiplyCollateralId(
  ctx: MutationCtx,
  marketSlug: string | undefined,
  clientAssetId: string | undefined,
): Promise<string | undefined> {
  if (!marketSlug) return undefined
  const market = await ctx.db
    .query("markets")
    .withIndex("by_scope_slug", (q) => q.eq("scope", "multiply").eq("slug", marketSlug))
    .unique()
  const canonical = market?.symbol?.toLowerCase()
  if (!canonical) return undefined
  if (clientAssetId && liquidAssetIdFromArgs(clientAssetId) !== canonical) {
    throw codedError(`INVALID_TRANSITION: ${marketSlug} collateral is ${canonical}, not ${clientAssetId}.`)
  }
  return canonical
}

async function priorMultiplyEquityUsd(
  ctx: MutationCtx,
  prior: Doc<"positions"> | undefined,
  collateralAssetId: string | undefined,
  now: number,
) {
  const storedEquityUsd = Math.max(0, (prior?.collateralValueUsd ?? 0) - (prior?.debtValueUsd ?? 0))
  const collateralAmount = prior?.collateralAmount ?? 0
  if (!prior || !(collateralAmount > 0) || !collateralAssetId) return storedEquityUsd
  const livePriceUsd = await validatedTokenPriceUsd(ctx, liquidAssetIdFromArgs(collateralAssetId), now)
  if (!livePriceUsd) return storedEquityUsd
  return Math.max(0, collateralAmount * livePriceUsd - (prior.debtValueUsd ?? 0))
}

/** Resolve and validate the wallet-owned equity source for a Multiply increase. */
async function multiplyLiquidDebit(
  ctx: MutationCtx,
  wallet: string,
  args: { product: "borrow" | "lend" | "multiply"; position?: Infer<typeof positionPayload> },
  existing: Doc<"positions"> | undefined,
  now: number,
): Promise<{ assetId: string; symbol: string; tokenAmount: number } | null> {
  if (args.product !== "multiply" || !args.position || args.position.status === "closed") return null
  const collateralId = await canonicalMultiplyCollateralId(ctx, args.position.marketSlug, args.position.assetId)
  const previousEquityUsd = await priorMultiplyEquityUsd(ctx, existing, collateralId, now)
  const nextEquityUsd = Math.max(0, (args.position.collateralValueUsd ?? 0) - (args.position.debtValueUsd ?? 0))
  const increaseUsd = nextEquityUsd - previousEquityUsd
  if (increaseUsd <= 0.02) return null
  const marketSlug = args.position.marketSlug
  const assetId = liquidAssetIdFromArgs(args.position.assetId, marketSlug)
  const multiplyRows = await ctx.db
    .query("walletMultiplyBalances")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const explicitUsd = multiplyRows
    .filter((row) => row.marketId === marketSlug && row.assetId === assetId && row.state === "available")
    .reduce((sum, row) => sum + row.valueUsd, 0)
  if (explicitUsd > 0) {
    if (explicitUsd + 0.02 < increaseUsd) {
      throw codedError("INSUFFICIENT_BALANCE: not enough Multiply collateral for this action.")
    }
    return null
  }
  const liquid = await readWalletLiquidBalance(ctx, wallet, assetId)
  if (!liquid || !(liquid.amount > 0)) {
    throw codedError("INSUFFICIENT_BALANCE: not enough wallet collateral for this Multiply action.")
  }
  // Tokens at today's price, not the row's cost basis: at the cost basis ($105/AAVE) a $138 top-up
  // debited 1.31 AAVE for 1 AAVE of collateral.
  const priceUsd =
    (await validatedTokenPriceUsd(ctx, assetId, now)) ??
    (liquid.valueUsd > 0 ? liquid.valueUsd / liquid.amount : undefined)
  if (!priceUsd || liquid.amount * priceUsd + 0.02 < increaseUsd) {
    throw codedError("INSUFFICIENT_BALANCE: not enough wallet collateral for this Multiply action.")
  }
  return { assetId, symbol: liquid.symbol, tokenAmount: increaseUsd / priceUsd }
}

function _canonicalLedgerDelta(
  args: {
    product: "borrow" | "lend" | "multiply"
    kind: string
    marketSlug?: string
    assetId?: string
    amountUsd: number
    position?: Infer<typeof positionPayload>
  },
  existing?: Doc<"positions">,
) {
  if (args.product === "borrow") {
    const marketSlug = args.kind === "borrow" || args.kind === "repay" ? args.assetId : args.marketSlug
    if (!marketSlug || args.kind === "claim") return null
    return {
      marketSlug,
      borrowedDeltaUsd: args.kind === "borrow" ? args.amountUsd : args.kind === "repay" ? -args.amountUsd : 0,
      suppliedDeltaUsd: args.kind === "deposit" ? args.amountUsd : args.kind === "withdraw" ? -args.amountUsd : 0,
    }
  }
  if (args.product === "lend") {
    if (!args.marketSlug || args.kind === "claim") return null
    return {
      marketSlug: args.marketSlug,
      borrowedDeltaUsd: 0,
      suppliedDeltaUsd: args.kind === "deposit" ? args.amountUsd : -args.amountUsd,
    }
  }
  if (!args.marketSlug || !args.position) return null
  return {
    marketSlug: args.marketSlug,
    borrowedDeltaUsd: (args.position.debtValueUsd ?? 0) - (existing?.debtValueUsd ?? 0),
    suppliedDeltaUsd: (args.position.collateralValueUsd ?? 0) - (existing?.collateralValueUsd ?? 0),
  }
}

type PortfolioSnapshotValue = {
  wallet: string
  at: number
  totalValueUsd: number
  totalSuppliedUsd: number
  totalBorrowedUsd: number
  availableToBorrowUsd: number
  totalMultiplyExposureUsd: number
  totalEarnedUsd: number
}

/**
 * Read the wallet's current-portfolio row tolerantly. Concurrent snapshot writers can leave
 * >1 row, and `.unique()` would then throw and brick every portfolio read plus the onboarding
 * claim. Returns the newest; `upsertPortfolioCurrent` self-heals the duplicates.
 */
async function latestPortfolioCurrent(ctx: QueryCtx | MutationCtx, wallet: string) {
  const rows = await ctx.db
    .query("portfolioCurrent")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  if (rows.length <= 1) return rows[0] ?? null
  return rows.reduce((newest, row) => (row._creationTime > newest._creationTime ? row : newest), rows[0])
}

/**
 * The ONLY safe way to write portfolioCurrent: replace the newest row, delete duplicates a
 * prior race left behind, insert when none exist. A bare `insert` creates a second row
 * whenever the dashboard already wrote one, which bricks `.unique()`.
 */
export async function upsertPortfolioCurrent(ctx: MutationCtx, wallet: string, snapshot: PortfolioSnapshotValue) {
  const rows = await ctx.db
    .query("portfolioCurrent")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  if (rows.length === 0) {
    await ctx.db.insert("portfolioCurrent", snapshot)
    return
  }
  const sorted = [...rows].sort((left, right) => right._creationTime - left._creationTime)
  await ctx.db.replace(sorted[0]._id, snapshot)
  for (const extra of sorted.slice(1)) await ctx.db.delete(extra._id)
}

export async function appendPortfolioSnapshot(ctx: MutationCtx, wallet: string, now: number) {
  const [positions, balances, walletDebts, walletCollateral] = await Promise.all([
    ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("walletLiquidBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("walletDebts")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("walletCollateralPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
  ])
  const open = positions.filter((position) => position.status === "open")
  const liquid = balances.reduce((sum, balance) => sum + balance.valueUsd, 0)
  const borrowPositions = open.filter((position) => position.product === "borrow")
  const marketsWithLiveBorrow = new Set(borrowPositions.map((position) => position.marketSlug))
  const borrowCollateral = borrowPositions.reduce((sum, position) => sum + usd6Number(position.collateralValueUsd6), 0)
  const borrowDebt = borrowPositions.reduce((sum, position) => sum + usd6Number(position.debtValueUsd6), 0)
  // Home-seed tables fill markets that have not yet been written into `positions`, so the
  // Convex portfolio chart matches the dashboard/home cards before the first borrow action.
  const seedCollateral = walletCollateral
    .filter((row) => !marketsWithLiveBorrow.has(row.marketId))
    .reduce((sum, row) => sum + row.collateralUsd, 0)
  const seedDebt = walletDebts
    .filter((row) => !marketsWithLiveBorrow.has(row.marketId))
    .reduce((sum, row) => sum + row.amountUsd, 0)
  const totalBorrowCollateral = borrowCollateral + seedCollateral
  const totalBorrowDebt = borrowDebt + seedDebt
  const lendSupplied = open
    .filter((position) => position.product === "lend")
    .reduce((sum, position) => sum + usd6Number(position.suppliedUsd6), 0)
  const earned = open
    .filter((position) => position.product === "lend")
    .reduce((sum, position) => sum + usd6Number(position.earnedUsd6), 0)
  const multiplyCollateral = open
    .filter((position) => position.product === "multiply")
    .reduce((sum, position) => sum + (position.collateralValueUsd ?? 0), 0)
  const multiplyDebt = open
    .filter((position) => position.product === "multiply")
    .reduce((sum, position) => sum + (position.debtValueUsd ?? 0), 0)
  // Umbrella is deliberately EXCLUDED from portfolio value, as it is from the dashboard
  // headline, the Net APY blend and the onboarding snapshot. Folding it in only here made
  // stored history diverge from the live headline and tripped the chart's basis-tolerance gate.

  // ATB from per-pool collateral factors — never a hardcoded *0.7.
  const borrowSlugs = [
    ...new Set([
      ...borrowPositions.map((position) => position.marketSlug).filter(Boolean),
      ...walletCollateral.filter((row) => !marketsWithLiveBorrow.has(row.marketId)).map((row) => row.marketId),
    ]),
  ]
  const borrowPools = await Promise.all(
    borrowSlugs.map((slug) =>
      ctx.db
        .query("pools")
        .withIndex("by_slug", (q) => q.eq("slug", slug))
        .unique(),
    ),
  )
  const maxLtvBySlug = new Map(
    borrowPools
      .filter((pool): pool is NonNullable<typeof pool> => pool !== null)
      .map((pool) => [pool.slug, pool.maxLtvPct / 100] as const),
  )
  for (const row of walletCollateral) {
    if (marketsWithLiveBorrow.has(row.marketId) || maxLtvBySlug.has(row.marketId)) continue
    maxLtvBySlug.set(row.marketId, row.maxLtvPct / 100)
  }
  const borrowCapacityUsd =
    borrowPositions.reduce((sum, position) => {
      const collateralUsd = usd6Number(position.collateralValueUsd6)
      const cf = maxLtvBySlug.get(position.marketSlug) ?? BORROW_FALLBACK_LIQUIDATION_PCT / 100
      return sum + collateralUsd * cf
    }, 0) +
    walletCollateral
      .filter((row) => !marketsWithLiveBorrow.has(row.marketId))
      .reduce((sum, row) => {
        const cf = maxLtvBySlug.get(row.marketId) ?? row.maxLtvPct / 100
        return sum + row.collateralUsd * cf
      }, 0)

  const snapshot = {
    wallet,
    at: now,
    totalValueUsd: liquid + totalBorrowCollateral - totalBorrowDebt + lendSupplied + multiplyCollateral - multiplyDebt,
    totalSuppliedUsd: totalBorrowCollateral + lendSupplied + multiplyCollateral,
    totalBorrowedUsd: totalBorrowDebt + multiplyDebt,
    availableToBorrowUsd: Math.max(0, borrowCapacityUsd - totalBorrowDebt),
    totalMultiplyExposureUsd: multiplyCollateral,
    totalEarnedUsd: earned,
  }

  await upsertPortfolioCurrent(ctx, wallet, snapshot)

  const latestHistory = await ctx.db
    .query("portfolioSnapshots")
    .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
    .order("desc")
    .first()
  if (!latestHistory || now - latestHistory.at >= PORTFOLIO_HISTORY_INTERVAL_MS) {
    await ctx.db.insert("portfolioSnapshots", snapshot)
    const history = await ctx.db
      .query("portfolioSnapshots")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .take(MAX_PORTFOLIO_HISTORY_ROWS + 1)
    for (const expired of history.slice(MAX_PORTFOLIO_HISTORY_ROWS)) {
      await ctx.db.delete(expired._id)
    }
  }
}

/**
 * Append a delta event to the shared liquidity ledger and bump the aggregate cache.
 * Auth-gated callers (liquidation) use this instead of the internal `recordDelta` API.
 */
export async function applyLedgerDelta(
  ctx: MutationCtx,
  marketSlug: string,
  borrowedDeltaUsd: number,
  suppliedDeltaUsd: number,
  now: number,
) {
  await appendLiquidityDelta(ctx, {
    marketSlug,
    borrowedDeltaUsd,
    suppliedDeltaUsd,
    updatedAt: now,
  })
}

/**
 * Persist the remaining claimable per borrow LP-fee reward position. Stored as an ABSOLUTE
 * per-(wallet, rewardPositionId) value, so hydration reduces the seeded claimable to it and
 * replaying the same claim is idempotent by construction.
 */
async function applyRewardClaims(
  ctx: MutationCtx,
  wallet: string,
  claims: Array<{ rewardPositionId: string; remainingUsd6: string }>,
  now: number,
) {
  for (const claim of claims) {
    requireUnsignedInteger(claim.remainingUsd6, "remainingUsd6")
    const existing = await ctx.db
      .query("sandboxRewardClaims")
      .withIndex("by_wallet_position", (q) => q.eq("wallet", wallet).eq("rewardPositionId", claim.rewardPositionId))
      .unique()
    if (existing) {
      await ctx.db.patch(existing._id, { remainingUsd6: claim.remainingUsd6, updatedAt: now })
    } else {
      await ctx.db.insert("sandboxRewardClaims", {
        wallet,
        rewardPositionId: claim.rewardPositionId,
        remainingUsd6: claim.remainingUsd6,
        updatedAt: now,
      })
    }
    // Keep home claim cards (walletClaimPositions) aligned with the durable remaining.
    const homeClaim = await ctx.db
      .query("walletClaimPositions")
      .withIndex("by_wallet_claim", (q) => q.eq("wallet", wallet).eq("claimId", claim.rewardPositionId))
      .unique()
    if (homeClaim) {
      const remainingUsd = Number(claim.remainingUsd6) / 1_000_000
      await ctx.db.patch(homeClaim._id, {
        totalUsd: Number.isFinite(remainingUsd) ? Math.max(0, remainingUsd) : 0,
        updatedAt: now,
      })
    }
  }
}

/**
 * Mirror a durable borrow `positions` row into the home-seed tables so home cards and
 * dashboard hydrate stay on one truth after the first action for a market.
 */
async function syncHomeBorrowMirrors(
  ctx: MutationCtx,
  wallet: string,
  marketSlug: string,
  position: Infer<typeof positionPayload>,
  now: number,
) {
  const closed = position.status === "closed"
  const collateralFromLegs = (position.collateral ?? []).reduce(
    (sum, leg) => sum + (leg.collateralValueUsd6 ? usd6Number(leg.collateralValueUsd6) : 0),
    0,
  )
  const collateralUsd = closed
    ? 0
    : (position.collateralValueUsd ??
      ((position.collateralValueUsd6 ? usd6Number(position.collateralValueUsd6) : 0) || collateralFromLegs))
  const debtLegs =
    position.debt?.map((leg) => ({
      debtAssetId: leg.baseAssetId || leg.assetId.split(":").pop() || leg.assetId,
      amountUsd: closed ? 0 : Number(leg.principalBorrowedUsd6) / 1_000_000,
    })) ?? []
  const debtUsd = closed
    ? 0
    : debtLegs.length > 0
      ? debtLegs.reduce((sum, leg) => sum + (Number.isFinite(leg.amountUsd) ? leg.amountUsd : 0), 0)
      : (position.debtValueUsd ?? usd6Number(position.debtValueUsd6))

  const [collateralRows, debtRows] = await Promise.all([
    ctx.db
      .query("walletCollateralPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("walletDebts")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
  ])
  const collateralMatch = collateralRows.find((row) => row.marketId === marketSlug)
  if (collateralMatch) {
    if (closed || collateralUsd <= 0) {
      await ctx.db.delete(collateralMatch._id)
    } else {
      const maxLtvPct = collateralMatch.maxLtvPct
      await ctx.db.patch(collateralMatch._id, {
        collateralUsd,
        borrowPowerUsd: collateralUsd * (maxLtvPct / 100),
        updatedAt: now,
      })
    }
  }

  const debtsForMarket = debtRows.filter((row) => row.marketId === marketSlug)
  if (closed || debtUsd <= 0) {
    for (const row of debtsForMarket) await ctx.db.delete(row._id)
    return
  }

  if (debtLegs.length > 0) {
    for (const leg of debtLegs) {
      if (!(leg.amountUsd > 0)) continue
      const existing = debtsForMarket.find((row) => row.debtAssetId === leg.debtAssetId)
      if (existing) {
        await ctx.db.patch(existing._id, { amountUsd: leg.amountUsd, updatedAt: now })
      } else if (collateralMatch) {
        await ctx.db.insert("walletDebts", {
          wallet,
          homePoolId: collateralMatch.homePoolId,
          marketId: marketSlug,
          debtAssetId: leg.debtAssetId,
          amountUsd: leg.amountUsd,
          updatedAt: now,
        })
      }
    }
    for (const row of debtsForMarket) {
      if (!debtLegs.some((leg) => leg.debtAssetId === row.debtAssetId && leg.amountUsd > 0)) {
        await ctx.db.delete(row._id)
      }
    }
    return
  }

  const existing = debtsForMarket[0]
  if (existing) {
    await ctx.db.patch(existing._id, { amountUsd: debtUsd, updatedAt: now })
  } else if (collateralMatch) {
    await ctx.db.insert("walletDebts", {
      wallet,
      homePoolId: collateralMatch.homePoolId,
      marketId: marketSlug,
      debtAssetId: position.assetId?.split(":").pop() || "usdc",
      amountUsd: debtUsd,
      updatedAt: now,
    })
  }
}

/**
 * Persist one balance-changing sandbox action. Returns a synthetic receipt the UI
 * renders exactly like the in-browser adapter's (`{ id, hash, status, simulated }`).
 */
export const recordTransaction = mutation({
  args: {
    wallet: v.string(),
    /** Client intent id — the idempotency key (replays return the existing row). */
    intentId: v.string(),
    product: v.union(v.literal("borrow"), v.literal("lend"), v.literal("multiply")),
    kind: v.string(),
    status: v.optional(v.union(v.literal("success"), v.literal("failed"), v.literal("pending"))),
    marketSlug: v.optional(v.string()),
    assetId: v.optional(v.string()),
    requestedAmountUsd6: v.string(),
    executedAmountUsd6: v.string(),
    amountUsd: v.number(),
    /** Lend deposit/withdraw: the typed token quantity, booked when its price matches the oracle. */
    tokenAmount: v.optional(v.number()),
    simulated: v.optional(v.boolean()),
    healthFactorWadBefore: v.optional(v.union(v.string(), v.null())),
    healthFactorWadAfter: v.optional(v.union(v.string(), v.null())),
    /** Per-transaction multiply leverage, persisted so hydrated history renders the real
     *  before→after instead of a constant 1 × the position's current multiplier. */
    multiplierBefore: v.optional(v.number()),
    multiplierAfter: v.optional(v.number()),
    position: v.optional(positionPayload),
    /**
     * The `positions.revision` the client read before computing this write. If the stored
     * position has since advanced, the write is rejected (STALE_WRITE) rather than
     * overwriting the concurrent change.
     */
    expectedRevision: v.optional(v.number()),
    /** Remaining claimable per borrow LP-fee reward position after this claim (usd6 decimal
     *  strings). Sent only for a borrow "claim"; persisted so claimable survives reload. */
    rewardClaims: v.optional(v.array(v.object({ rewardPositionId: v.string(), remainingUsd6: v.string() }))),
    // Deliberately no client `ledger` arg: the aggregate market-liquidity delta is recomputed
    // server-side (canonicalLedgerDelta) so a client can never dictate the shared ledger.
  },
  handler: async (ctx, args) =>
    withClientErrorCode(async () => {
      const wallet = await requireSandboxWallet(ctx, args.wallet)
      requireBoundedIdentifier(args.intentId, "intentId")
      if (args.marketSlug !== undefined) requireBoundedIdentifier(args.marketSlug, "marketSlug")
      if (args.assetId !== undefined) requireBoundedIdentifier(args.assetId, "assetId")
      if ((args.rewardClaims?.length ?? 0) > MAX_POSITION_LEGS) {
        throw codedError(`INVALID_INPUT: rewardClaims may contain at most ${MAX_POSITION_LEGS} rows.`)
      }
      for (const claim of args.rewardClaims ?? []) {
        requireBoundedIdentifier(claim.rewardPositionId, "rewardPositionId")
        requireUnsignedInteger(claim.remainingUsd6, "remainingUsd6")
      }
      const now = Date.now()

      // Idempotency — a replayed intent returns the existing row, never double-applies.
      const prior = await ctx.db
        .query("transactions")
        .withIndex("by_wallet_intent", (q) => q.eq("wallet", wallet).eq("intentId", args.intentId))
        .first()
      if (prior) {
        // Return the position's CURRENT revision so a client whose original response was lost
        // seeds its concurrency map from the replay; without it the next write sends no
        // expectedRevision and fails REVISION_REQUIRED.
        const priorPosition = prior.positionId ? await ctx.db.get(prior.positionId) : null
        return {
          idempotent: true,
          transactionId: prior._id,
          positionId: prior.positionId ?? null,
          revision: priorPosition?.revision ?? null,
          receipt: {
            id: prior._id,
            hash: prior.syntheticTxHash,
            status: prior.status,
            simulated: prior.simulated,
            timestamp: prior.at,
          },
        }
      }

      // Hourly per-wallet rate limit. `take(MAX_TX_PER_HOUR)` bounds the read instead of
      // collecting the wallet's entire trailing-hour history just to count it.
      const windowStart = now - 60 * 60 * 1000
      const recent = await ctx.db
        .query("transactions")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet).gte("at", windowStart))
        .take(MAX_TX_PER_HOUR)
      if (recent.length >= MAX_TX_PER_HOUR) {
        throw codedError(`RATE_LIMITED: more than ${MAX_TX_PER_HOUR} sandbox transactions in the last hour.`)
      }

      const status = args.status ?? "success"
      const simulated = args.simulated ?? true
      const marketSlug = args.position?.marketSlug ?? args.marketSlug
      const hash = `sim-${args.product}-${args.kind}-${args.intentId.slice(0, 8)}-${now.toString(36)}`

      // Pre-transaction lend supplied from the product-balance ledger, which the transition check
      // must use instead of the positions row — that row can lag out of sync.
      let lendSuppliedBeforeUsd: number | undefined
      // Token price implied by the supplied ledger (token-denominated since #296): the conversion
      // fallback for a lend withdraw of an asset the oracle does not cover, such as stocks.
      let lendLedgerPriceUsd: number | undefined
      let lendTokenMove: LendTokenMove | undefined
      if (args.product === "lend" && marketSlug && args.kind !== "claim") {
        const deposited = (
          await ctx.db
            .query("walletLendBalances")
            .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
            .collect()
        ).filter((row) => row.marketId === marketSlug && row.state === "deposited")
        lendSuppliedBeforeUsd = deposited.reduce((sum, row) => sum + row.valueUsd, 0)
        const depositedAmount = deposited.reduce((sum, row) => sum + row.amount, 0)
        if (depositedAmount > 0 && lendSuppliedBeforeUsd > 0)
          lendLedgerPriceUsd = lendSuppliedBeforeUsd / depositedAmount
        // The deposited token count is the balance; `valueUsd` is the USD at deposit. Withdrawing
        // by that USD paid out tokens at today's price: 25,685 OP deposited at $1.46 could be
        // withdrawn as ~300,000 OP at $0.12. Price the action and the balance in tokens.
        const priceUsd =
          (await validatedTokenPriceUsd(ctx, liquidAssetIdFromArgs(args.assetId, marketSlug), now)) ??
          lendLedgerPriceUsd
        if (priceUsd && priceUsd > 0) {
          // Book the typed quantity when the client priced it within 2% of the oracle (it reads
          // the same feed moments apart), so 0.5 AAVE moves 0.5, not 0.502.
          const typed = args.tokenAmount
          const typedMatches =
            typed !== undefined && typed > 0 && Math.abs(args.amountUsd / typed / priceUsd - 1) <= 0.02
          const tokens = typedMatches ? typed : args.amountUsd / priceUsd
          lendTokenMove = { tokens, priceUsd: tokens > 0 && args.amountUsd > 0 ? args.amountUsd / tokens : priceUsd }
          if (depositedAmount > 0) lendSuppliedBeforeUsd = depositedAmount * priceUsd
          if (args.kind === "withdraw") {
            // Accrual is bounded by the persisted position's last rate and checkpoint. The
            // incoming client payload is not authoritative, and a blanket rate can mint yield.
            const position = await ctx.db
              .query("positions")
              .withIndex("by_wallet_product_market", (q) =>
                q.eq("wallet", wallet).eq("product", "lend").eq("marketSlug", marketSlug),
              )
              .unique()
            const lastWriteAt = position?.lastUpdatedAt ?? Math.max(...deposited.map((row) => row.updatedAt ?? now), 0)
            const years = Math.max(0, now - lastWriteAt) / (365 * 24 * 3600 * 1000)
            const storedApyPct = position?.supplyApyPct
            const apy =
              typeof storedApyPct === "number" && Number.isFinite(storedApyPct) ? Math.max(0, storedApyPct) : 0
            const maxTokens = depositedAmount * Math.pow(1 + apy / 100, years) * (1 + 1e-6) + 1e-9
            if (tokens > maxTokens) {
              throw codedError("INSUFFICIENT_BALANCE: withdraw exceeds the deposited amount.")
            }
          }
        }
      }

      let positionId: import("../_generated/dataModel").Id<"positions"> | undefined
      let existingPosition: Doc<"positions"> | undefined
      // Revision actually written, returned so the client seeds its concurrency map from server
      // truth instead of inferring it.
      let writtenRevision: number | undefined
      let multiplyDebit: { assetId: string; symbol: string; tokenAmount: number } | null = null
      if (args.position && status === "success" && marketSlug) {
        validatePositionPayload(args.position)
        const existing =
          (await ctx.db
            .query("positions")
            .withIndex("by_wallet_product_market", (q) =>
              q.eq("wallet", wallet).eq("product", args.product).eq("marketSlug", marketSlug),
            )
            .unique()) ?? undefined
        existingPosition = existing
        // Optimistic concurrency: reject a write computed from a stale read instead of
        // silently clobbering a concurrent one (two tabs on the same wallet/market).
        const currentRevision = existing?.revision ?? 0
        if (existing && args.expectedRevision == null) {
          throw codedError(
            `REVISION_REQUIRED: ${args.product} position for ${marketSlug} already exists; ` +
              "reload it and submit its expectedRevision.",
          )
        }
        if (existing && args.expectedRevision !== currentRevision) {
          throw codedError(
            `STALE_WRITE: ${args.product} position for ${marketSlug} changed since it was read ` +
              `(expected revision ${args.expectedRevision}, found ${currentRevision}); reload and retry.`,
          )
        }
        validateTransactionTransition(args, existing, lendSuppliedBeforeUsd)
        await assertBorrowCollateralConserved(ctx, wallet, args)
        await assertBorrowSolvent(ctx, args)
        multiplyDebit = await multiplyLiquidDebit(ctx, wallet, args, existing, now)
        const fields = {
          spokeId: args.position.spokeId,
          assetId: args.position.assetId ?? args.assetId,
          status: args.position.status,
          collateralValueUsd6: args.position.collateralValueUsd6,
          debtValueUsd6: args.position.debtValueUsd6,
          suppliedUsd6: args.position.suppliedUsd6,
          earnedUsd6: args.position.earnedUsd6,
          supplyApyPct: args.position.supplyApyPct,
          collateralAmount: args.position.collateralAmount,
          collateralValueUsd: args.position.collateralValueUsd,
          debtValueUsd: args.position.debtValueUsd,
          multiplier: args.position.multiplier,
          ltv: args.position.ltv,
          healthFactor: args.position.healthFactor,
          liquidationPrice: args.position.liquidationPrice,
          netApyPct: args.position.netApyPct,
          lastUpdatedAt: now,
          revision: existing ? currentRevision + 1 : 0,
          ...(args.position.status === "closed" ? { closedAt: now } : {}),
        }
        writtenRevision = fields.revision
        if (existing) {
          await ctx.db.patch(existing._id, fields)
          positionId = existing._id
        } else {
          positionId = await ctx.db.insert("positions", {
            wallet,
            product: args.product,
            marketSlug,
            openedAt: now,
            openTxSynthetic: hash,
            ...fields,
          })
        }

        if (args.product === "borrow" && positionId) {
          const [existingCollateral, existingDebt] = await Promise.all([
            ctx.db
              .query("positionCollateral")
              .withIndex("by_position", (q) => q.eq("positionId", positionId!))
              .collect(),
            ctx.db
              .query("positionDebt")
              .withIndex("by_position", (q) => q.eq("positionId", positionId!))
              .collect(),
          ])
          for (const row of existingCollateral) await ctx.db.delete(row._id)
          for (const row of existingDebt) await ctx.db.delete(row._id)
          for (const collateral of args.position.collateral ?? []) {
            await ctx.db.insert("positionCollateral", {
              wallet,
              positionId,
              ...collateral,
              updatedAt: now,
            })
          }
          for (const debt of args.position.debt ?? []) {
            await ctx.db.insert("positionDebt", {
              wallet,
              positionId,
              ...debt,
              updatedAt: now,
            })
          }
          await syncHomeBorrowMirrors(ctx, wallet, marketSlug, args.position, now)
        }
      }

      if (!args.position) validateTransactionTransition(args, undefined, lendSuppliedBeforeUsd)

      const transactionId = await ctx.db.insert("transactions", {
        wallet,
        intentId: args.intentId,
        product: args.product,
        kind: args.kind,
        status,
        marketSlug,
        assetId: args.assetId,
        positionId,
        requestedAmountUsd6: args.requestedAmountUsd6,
        executedAmountUsd6: args.executedAmountUsd6,
        amountUsd: args.amountUsd,
        healthFactorWadBefore: args.healthFactorWadBefore,
        healthFactorWadAfter: args.healthFactorWadAfter,
        multiplierBefore: args.multiplierBefore,
        multiplierAfter: args.multiplierAfter,
        tokenAmount: lendTokenMove?.tokens,
        syntheticTxHash: hash,
        simulated,
        at: now,
      })

      // Unify products on the shared aggregate ledger (auth-gated, attributed write).
      if (status === "success") {
        if (args.product === "borrow" && args.kind === "claim" && args.rewardClaims?.length) {
          await applyRewardClaims(ctx, wallet, args.rewardClaims, now)
        }
        // Keep liquid wallet balances durable for cash-moving actions (lend deposit/withdraw,
        // borrow/repay). The token delta is derived from USD at a real unit price: a missing or
        // zero liquid row used to fall back to $1/token, so withdrawing a $37,500 rETH lend leg
        // credited 37,500 rETH (~$120M). Same resolution as the product-balance writers (#296):
        // the row's own price when plausible, else the oracle, else the lend ledger's price for
        // assets the oracle does not cover; $1 only when no source exists at all.
        if (
          (args.product === "lend" && (args.kind === "deposit" || args.kind === "withdraw")) ||
          (args.product === "borrow" && (args.kind === "borrow" || args.kind === "repay"))
        ) {
          const assetId = liquidAssetIdFromArgs(args.assetId, marketSlug)
          const liquid = await readWalletLiquidBalance(ctx, wallet, assetId)
          const impliedPriceUsd =
            liquid && liquid.amount > 0 && liquid.valueUsd > 0 ? liquid.valueUsd / liquid.amount : null
          const oraclePriceUsd = await validatedTokenPriceUsd(ctx, assetId, now)
          const priceUsd =
            (args.product === "lend" ? lendTokenMove?.priceUsd : undefined) ??
            resolveWriteBackPriceUsd(impliedPriceUsd, oraclePriceUsd) ??
            lendLedgerPriceUsd ??
            1
          const tokenAmount = args.amountUsd / priceUsd
          const signed = args.kind === "deposit" || args.kind === "repay" ? -tokenAmount : tokenAmount
          // Affordability: a deposit/repay debit must be backed by an existing authenticated-wallet
          // liquid row with enough USD value. Never fail open when the row is absent: clamping that
          // nonexistent source to zero while crediting the product bucket mints net worth.
          if (
            args.product === "lend" &&
            args.kind === "deposit" &&
            (!liquid || liquid.amount + 1e-9 < (lendTokenMove?.tokens ?? tokenAmount))
          ) {
            throw codedError("INSUFFICIENT_BALANCE: not enough liquid tokens for this deposit.")
          }
          if (
            signed < 0 &&
            !(args.product === "lend" && args.kind === "deposit") &&
            (!liquid || liquid.valueUsd + 1e-6 < args.amountUsd)
          ) {
            throw codedError("INSUFFICIENT_BALANCE: not enough liquid balance for this action.")
          }
          await applyLiquidAssetDelta(ctx, wallet, assetId, canonicalTokenSymbolOrUpper(assetId), signed, now, priceUsd)
        }
        if (multiplyDebit) {
          await applyLiquidAssetDelta(
            ctx,
            wallet,
            multiplyDebit.assetId,
            multiplyDebit.symbol,
            -multiplyDebit.tokenAmount,
            now,
          )
        }
        await applyProductBucketDelta(ctx, wallet, args, marketSlug, now, existingPosition, lendTokenMove)
        await appendPortfolioSnapshot(ctx, wallet, now)
        if (args.product === "borrow") await appendServerRiskSnapshot(ctx, wallet, now, args.kind)
      }

      return {
        idempotent: false,
        transactionId,
        positionId: positionId ?? null,
        revision: writtenRevision ?? null,
        receipt: { id: transactionId, hash, status, simulated, timestamp: now },
      }
    }),
})

export const recordRewardsClaim = mutation({
  args: {
    wallet: v.string(),
    intentId: v.string(),
    // The quest ids being claimed. Payout is derived on-server from these, so a forged
    // amount cannot inflate totals.
    taskIds: v.array(v.string()),
    syntheticTxHash: v.string(),
    // Per-task receipt hashes, parallel to `taskIds`. When present and length-matched, each
    // quest gets its own transaction row carrying the same hash the client engine stamps on
    // its seed activity row, so the Activity feed dedups the two. Absent → one summed row.
    syntheticTxHashes: v.optional(v.array(v.string())),
  },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    requireBoundedIdentifier(args.intentId, "intentId")
    requireBoundedIdentifier(args.syntheticTxHash, "syntheticTxHash")
    if (args.taskIds.length > 32) throw codedError("INVALID_CLAIM: at most 32 task ids may be claimed at once")
    for (const taskId of args.taskIds) requireBoundedIdentifier(taskId, "taskId")
    const prior = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_intent", (q) => q.eq("wallet", wallet).eq("intentId", args.intentId))
      .first()
    if (prior) return { transactionId: prior._id, idempotent: true }

    const taskIds = args.taskIds
    if (taskIds.length === 0) throw codedError("EMPTY_CLAIM: at least one task id is required")
    if (new Set(taskIds).size !== taskIds.length) throw codedError("DUPLICATE_TASK_ID")
    const amountUsd = deriveClaimAmountUsd(taskIds)

    const [walletTransactions, rewardsState] = await Promise.all([
      ctx.db
        .query("transactions")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
        .order("desc")
        .take(1000),
      ctx.db
        .query("sandboxRewards")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .unique(),
    ])
    let events: Array<{ wallet?: string; type?: string; marketId?: string }> = []
    try {
      const parsed = rewardsState ? (JSON.parse(rewardsState.stateJson) as { events?: unknown }) : null
      if (Array.isArray(parsed?.events)) events = parsed.events as typeof events
    } catch {
      // saveState already rejects malformed JSON. Treat legacy malformed rows as no evidence.
    }
    const walletEvents = events.filter((event) => event.wallet?.toLowerCase() === wallet)
    const hasEvent = (type: string, marketId?: string) =>
      walletEvents.some((event) => event.type === type && (marketId == null || event.marketId === marketId))
    const successful = walletTransactions.filter((row) => row.status === "success")
    const isEligible = (taskId: string) => {
      switch (taskId) {
        case "connect-wallet":
          return true
        case "review-risk-basics":
          return hasEvent("education_completed")
        case "run-first-simulation":
          return hasEvent("simulation_created")
        case "favorite-market":
          return hasEvent("market_favorited")
        case "first-lend-deposit":
          return successful.some((row) => row.product === "lend" && row.kind === "deposit")
        case "supply-5k-lend":
          return (
            successful
              .filter((row) => row.product === "lend" && row.kind === "deposit")
              .reduce((sum, row) => sum + row.amountUsd, 0) >= 500
          )
        case "first-borrow":
          return successful.some((row) => row.product === "borrow" && row.kind === "borrow")
        case "first-repay":
          return successful.some((row) => row.product === "borrow" && row.kind === "repay")
        case "first-multiply":
          return successful.some((row) => row.product === "multiply" && row.kind === "multiply")
        case "first-deleverage":
          return successful.some((row) => row.product === "multiply" && row.kind === "deleverage")
        case "use-curve-position":
          return hasEvent("sandbox_tour_completed", "curve-sandbox-tour")
        case "use-uniswap-v4-position":
          return hasEvent("sandbox_tour_completed", "uniswap-v4-sandbox-tour")
        case "share-referral-link":
          return hasEvent("referral_link_created")
        case "invite-first-wallet":
          return hasEvent("referral_connected")
        case "bring-3-active-users":
          return walletEvents.filter((event) => event.type === "referral_activated").length >= 3
        default:
          return false
      }
    }
    for (const id of taskIds) {
      if (!isEligible(id)) throw codedError(`TASK_NOT_ELIGIBLE: ${id}`)
    }

    // Single-claim guard: reject any task id already paid out on a prior successful claim row
    // for this wallet. Durable, so a stale client rewards blob (multi-device, cold reload)
    // opens no double-claim window. Only enforceable on the catalog path — legacy claims
    // carry no task ids.
    const alreadyClaimed = new Set<string>()
    for (const row of walletTransactions) {
      if (row.product === "rewards" && row.kind === "claim" && row.status === "success" && row.claimedTaskIds) {
        for (const id of row.claimedTaskIds) alreadyClaimed.add(id)
      }
    }
    for (const id of taskIds) {
      if (alreadyClaimed.has(id)) {
        throw codedError(`TASK_ALREADY_CLAIMED: ${id}`)
      }
    }

    const now = Date.now()

    // One transaction per claimed quest so each durable row dedups against its quest-titled
    // seed activity row. Payout stays catalog-derived per task, never trusted from the client.
    const perTaskHashes = args.syntheticTxHashes
    if (perTaskHashes && perTaskHashes.length === taskIds.length) {
      for (const hash of perTaskHashes) requireBoundedIdentifier(hash, "syntheticTxHash")
      const insertedIds = []
      for (let index = 0; index < taskIds.length; index += 1) {
        const taskId = taskIds[index]
        const taskAmountUsd = deriveClaimAmountUsd([taskId])
        insertedIds.push(
          await ctx.db.insert("transactions", {
            wallet,
            intentId: args.intentId,
            product: "rewards",
            kind: "claim",
            status: "success",
            assetId: "ava",
            requestedAmountUsd6: String(Math.round(taskAmountUsd * 1_000_000)),
            executedAmountUsd6: String(Math.round(taskAmountUsd * 1_000_000)),
            amountUsd: taskAmountUsd,
            claimedTaskIds: [taskId],
            syntheticTxHash: perTaskHashes[index],
            simulated: true,
            at: now,
          }),
        )
      }
      await appendPortfolioSnapshot(ctx, wallet, now)
      return { transactionId: insertedIds[0], idempotent: false, amountUsd }
    }

    const transactionId = await ctx.db.insert("transactions", {
      wallet,
      intentId: args.intentId,
      product: "rewards",
      kind: "claim",
      status: "success",
      assetId: "ava",
      requestedAmountUsd6: String(Math.round(amountUsd * 1_000_000)),
      executedAmountUsd6: String(Math.round(amountUsd * 1_000_000)),
      amountUsd,
      claimedTaskIds: taskIds,
      syntheticTxHash: args.syntheticTxHash,
      simulated: true,
      at: now,
    })
    await appendPortfolioSnapshot(ctx, wallet, now)
    return { transactionId, idempotent: false, amountUsd }
  },
})

type LendTokenMove = { tokens: number; priceUsd: number }

/**
 * Moves a token quantity on a lend ledger row. A credit adds its USD to the cost basis; a debit
 * scales the basis by the tokens left, so `valueUsd` stays the USD paid for the tokens held.
 */
async function adjustLendTokenRow(
  ctx: MutationCtx,
  wallet: string,
  match: { marketId: string; assetId: string; state: "available" | "deposited" },
  symbol: string,
  deltaTokens: number,
  amountUsd: number,
  now: number,
) {
  if (!Number.isFinite(deltaTokens) || deltaTokens === 0) return
  const existing = (
    await ctx.db
      .query("walletLendBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
  ).find((row) => row.state === match.state && row.marketId === match.marketId && row.assetId === match.assetId)
  const amount = existing?.amount ?? 0
  const nextAmount = Math.max(0, amount + deltaTokens)
  const nextValueUsd =
    deltaTokens > 0
      ? (existing?.valueUsd ?? 0) + amountUsd
      : amount > 0
        ? (existing?.valueUsd ?? 0) * (nextAmount / amount)
        : 0
  if (existing) {
    await ctx.db.patch(existing._id, { amount: nextAmount, valueUsd: nextValueUsd, updatedAt: now })
    return
  }
  if (nextAmount <= 0) return
  await ctx.db.insert("walletLendBalances", {
    wallet,
    ...match,
    symbol,
    amount: nextAmount,
    valueUsd: nextValueUsd,
    updatedAt: now,
  })
}

async function applyProductBucketDelta(
  ctx: MutationCtx,
  wallet: string,
  args: {
    product: "borrow" | "lend" | "multiply"
    kind: string
    marketSlug?: string
    assetId?: string
    amountUsd: number
    position?: Infer<typeof positionPayload>
    rewardClaims?: Array<{ rewardPositionId: string; remainingUsd6: string }>
  },
  marketSlug: string | undefined,
  now: number,
  priorPosition?: Doc<"positions">,
  lendTokenMove?: LendTokenMove,
) {
  const assetId = liquidAssetIdFromArgs(args.assetId, marketSlug)
  if (args.product === "lend" && marketSlug && lendTokenMove && (args.kind === "deposit" || args.kind === "withdraw")) {
    const sign = args.kind === "deposit" ? 1 : -1
    const symbol = canonicalTokenSymbolOrUpper(assetId)
    await adjustLendTokenRow(
      ctx,
      wallet,
      { marketId: marketSlug, assetId, state: "deposited" },
      symbol,
      sign * lendTokenMove.tokens,
      args.amountUsd,
      now,
    )
    await adjustLendTokenRow(
      ctx,
      wallet,
      { marketId: marketSlug, assetId, state: "available" },
      symbol,
      -sign * lendTokenMove.tokens,
      args.amountUsd,
      now,
    )
    return
  }
  if (args.product === "lend" && marketSlug) {
    if (args.kind === "deposit") {
      await adjustProductBalanceUsd(
        ctx,
        "walletLendBalances",
        wallet,
        { marketId: marketSlug, assetId, state: "available" },
        canonicalTokenSymbolOrUpper(assetId),
        -args.amountUsd,
        now,
      )
      await adjustProductBalanceUsd(
        ctx,
        "walletLendBalances",
        wallet,
        { marketId: marketSlug, assetId, state: "deposited" },
        canonicalTokenSymbolOrUpper(assetId),
        args.amountUsd,
        now,
      )
    } else if (args.kind === "withdraw") {
      await adjustProductBalanceUsd(
        ctx,
        "walletLendBalances",
        wallet,
        { marketId: marketSlug, assetId, state: "deposited" },
        canonicalTokenSymbolOrUpper(assetId),
        -args.amountUsd,
        now,
      )
      await adjustProductBalanceUsd(
        ctx,
        "walletLendBalances",
        wallet,
        { marketId: marketSlug, assetId, state: "available" },
        canonicalTokenSymbolOrUpper(assetId),
        args.amountUsd,
        now,
      )
    }
    return
  }

  if (args.product === "borrow") {
    if (marketSlug && (args.kind === "deposit" || args.kind === "withdraw")) {
      if (args.position) {
        await syncBorrowProductCollateralRows(ctx, wallet, marketSlug, args.position, now)
      } else {
        const signed = args.kind === "deposit" ? args.amountUsd : -args.amountUsd
        await adjustProductBalanceUsd(
          ctx,
          "walletBorrowBalances",
          wallet,
          { marketId: marketSlug, state: "poolAvailable" },
          canonicalTokenSymbolOrUpper(marketSlug),
          -signed,
          now,
        )
        await adjustProductBalanceUsd(
          ctx,
          "walletBorrowBalances",
          wallet,
          { marketId: marketSlug, state: "collateral" },
          canonicalTokenSymbolOrUpper(marketSlug),
          signed,
          now,
        )
      }
    }
    if (args.kind === "borrow" || args.kind === "repay") {
      const debtAssetId = liquidAssetIdFromArgs(args.assetId, marketSlug)
      await adjustProductBalanceUsd(
        ctx,
        "walletBorrowBalances",
        wallet,
        { marketId: marketSlug, assetId: debtAssetId, state: "debt" },
        canonicalTokenSymbolOrUpper(debtAssetId),
        args.kind === "borrow" ? args.amountUsd : -args.amountUsd,
        now,
      )
    }
    if (args.kind === "claim" && args.rewardClaims?.length) {
      for (const claim of args.rewardClaims) {
        await adjustProductBalanceUsd(
          ctx,
          "walletBorrowBalances",
          wallet,
          { assetId: claim.rewardPositionId, state: "claimableFees" },
          "Fees",
          -args.amountUsd,
          now,
        )
      }
    }
    return
  }

  if (args.product === "multiply" && marketSlug && args.position) {
    const baseAsset = liquidAssetIdFromArgs(args.position.assetId ?? args.assetId, marketSlug)
    const collateralValueUsd = args.position.status === "closed" ? 0 : (args.position.collateralValueUsd ?? 0)
    const debtValueUsd = args.position.status === "closed" ? 0 : (args.position.debtValueUsd ?? 0)
    const collateralAmount =
      args.position.status === "closed" ? 0 : (args.position.collateralAmount ?? collateralValueUsd)
    const collateralId = await canonicalMultiplyCollateralId(ctx, marketSlug, args.position.assetId)
    const previousEquityUsd = await priorMultiplyEquityUsd(ctx, priorPosition, collateralId, now)
    const nextEquityUsd = Math.max(0, collateralValueUsd - debtValueUsd)
    // `deltaUsd` is USD but walletMultiplyBalances.amount is a TOKEN QUANTITY, so a real
    // price is required — a $1/token default once persisted 41,666 WSTETH for a $41.6K
    // position ($123M on the dashboard). Prefer the market's canonical collateral-token
    // price, falling back to the wallet's live holding price only if the market row is gone.
    const [multiplyMarket, liquid] = await Promise.all([
      ctx.db
        .query("markets")
        .withIndex("by_scope_slug", (q) => q.eq("scope", "multiply").eq("slug", marketSlug))
        .unique(),
      readWalletLiquidBalance(ctx, wallet, baseAsset),
    ])
    const multiplyPriceUsd =
      multiplyMarket?.priceUsd && Number.isFinite(multiplyMarket.priceUsd) && multiplyMarket.priceUsd > 0
        ? multiplyMarket.priceUsd
        : liquid && liquid.amount > 0 && liquid.valueUsd > 0
          ? liquid.valueUsd / liquid.amount
          : undefined
    await adjustProductBalanceUsd(
      ctx,
      "walletMultiplyBalances",
      wallet,
      { marketId: marketSlug, assetId: baseAsset, state: "available" },
      canonicalTokenSymbolOrUpper(baseAsset),
      previousEquityUsd - nextEquityUsd,
      now,
      multiplyPriceUsd,
    )
    await upsertProductBalanceValue(ctx, "walletMultiplyBalances", wallet, {
      marketId: marketSlug,
      assetId: baseAsset,
      symbol: canonicalTokenSymbolOrUpper(baseAsset),
      amount: collateralAmount,
      valueUsd: collateralValueUsd,
      state: "position",
    })
    await upsertProductBalanceValue(ctx, "walletMultiplyBalances", wallet, {
      marketId: marketSlug,
      assetId: baseAsset,
      symbol: canonicalTokenSymbolOrUpper(baseAsset),
      amount: collateralAmount,
      valueUsd: collateralValueUsd,
      state: "collateral",
    })
    // Anchor to whatever asset the STORED debt row uses; only fall back to the slug-derived id
    // when opening a brand-new row. The debt asset is not encoded in every slug (reth-eth /
    // wsteth-eth / steth-eth borrow USDC, but `liquidAssetIdFromArgs` guesses "eth"), and a
    // wrong guess makes close write a $0 row under the wrong asset and ORPHAN the real debt —
    // collateral goes to 0 while the debt inflates portfolio debt forever.
    const existingMultiplyDebt = (
      await ctx.db
        .query("walletMultiplyBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect()
    ).find((row) => row.marketId === marketSlug && row.state === "debt")
    const debtAssetId = existingMultiplyDebt?.assetId ?? assetId
    // `amount` is a TOKEN QUANTITY, derived from the server oracle, with USD kept as the
    // canonical `valueUsd`. Writing `amount: debtValueUsd` only works for ~$1 stablecoins; for
    // ETH/WBTC debt the dashboard's `amount × livePrice` inflates it by the token price.
    const debtPriceUsd = await validatedTokenPriceUsd(ctx, debtAssetId, now)
    const debtAmount = debtPriceUsd && debtPriceUsd > 0 ? debtValueUsd / debtPriceUsd : debtValueUsd
    await upsertProductBalanceValue(ctx, "walletMultiplyBalances", wallet, {
      marketId: marketSlug,
      assetId: debtAssetId,
      symbol: existingMultiplyDebt?.symbol ?? canonicalTokenSymbolOrUpper(assetId),
      amount: debtAmount,
      valueUsd: debtValueUsd,
      state: "debt",
    })
  }
}

/**
 * Persist an executed swap. A swap is a pure liquid-balance move (debit input, credit output)
 * with no position, so it takes this path rather than `recordTransaction`'s position-oriented
 * transition validation, with the same ownership / idempotency / rate-limit guarantees.
 * Swaps are USD-neutral at the portfolio-net level, so no portfolio snapshot is appended.
 */
/**
 * Server-side USD price for a swap leg, from the live `tokenPrices` oracle; null when no
 * trustworthy price exists. A successful swap FAILS CLOSED on an unpriced leg — otherwise a
 * caller could pick two unknown symbols and mint an arbitrary output from client values.
 */
export const recordSwap = mutation({
  args: {
    wallet: v.string(),
    /** Client swap id — the idempotency key (replays return the existing row). */
    intentId: v.string(),
    status: v.optional(v.union(v.literal("success"), v.literal("failed"), v.literal("pending"))),
    inputAssetId: v.string(),
    outputAssetId: v.string(),
    inputSymbol: v.string(),
    outputSymbol: v.string(),
    inputAmount: v.number(),
    outputAmount: v.number(),
    /** USD value of the input leg (what the swap moved). */
    amountUsd: v.number(),
    /** Receipt detail — persisted so the synthetic-transaction receipt renders the full
     *  swap breakdown from the durable row alone (cross-device / after session history). */
    provider: v.optional(v.string()),
    quoteId: v.optional(v.string()),
    networkFeeUsd: v.optional(v.number()),
    minOutputAmount: v.optional(v.number()),
    priceImpactPct: v.optional(v.number()),
    slippageBps: v.optional(v.number()),
    simulated: v.optional(v.boolean()),
    /** Optional client tx hash; a synthetic one is derived when absent. */
    syntheticTxHash: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    requireBoundedIdentifier(args.intentId, "intentId")
    for (const [field, value] of Object.entries({
      inputAssetId: args.inputAssetId,
      outputAssetId: args.outputAssetId,
      inputSymbol: args.inputSymbol,
      outputSymbol: args.outputSymbol,
      provider: args.provider,
      quoteId: args.quoteId,
      syntheticTxHash: args.syntheticTxHash,
    })) {
      if (value !== undefined) requireBoundedIdentifier(value, field)
    }
    const now = Date.now()

    // Idempotency — a replayed swap id returns the existing row, never double-records.
    const prior = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_intent", (q) => q.eq("wallet", wallet).eq("intentId", args.intentId))
      .first()
    if (prior) {
      return {
        idempotent: true,
        transactionId: prior._id,
        receipt: {
          id: prior._id,
          hash: prior.syntheticTxHash,
          status: prior.status,
          simulated: prior.simulated,
          timestamp: prior.at,
        },
      }
    }

    // Same hourly per-wallet cap as recordTransaction (bounded read).
    const windowStart = now - 60 * 60 * 1000
    const recent = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet).gte("at", windowStart))
      .take(MAX_TX_PER_HOUR)
    if (recent.length >= MAX_TX_PER_HOUR) {
      throw codedError(`RATE_LIMITED: more than ${MAX_TX_PER_HOUR} sandbox transactions in the last hour.`)
    }

    const status = args.status ?? "success"
    const simulated = args.simulated ?? true
    // A failed/expired/rejected swap executed nothing, so its output leg is legitimately 0
    // (recordFailure). Only a successful swap must have moved a positive output; every swap
    // still needs a positive input (the amount attempted) and a non-negative USD value.
    const outputAmountValid = status === "success" ? args.outputAmount > 0 : args.outputAmount >= 0
    if (!(args.inputAmount > 0) || !outputAmountValid || !(args.amountUsd >= 0)) {
      throw codedError("INVALID_SWAP: input must be positive, output positive on success, USD non-negative.")
    }
    // Server-authoritative: the output + USD are recomputed from the LIVE oracle via the shared
    // swap engine and used for both the balance delta and the persisted row, so client quotes
    // never determine the result. There is no client-valued or missing-balance success path.
    let executedOutputAmount = args.outputAmount
    let executedAmountUsd = args.amountUsd
    // Symbols come from the asset ids, never from the client: pricing one asset while moving
    // another (inputSymbol "WBTC" on an inputAssetId "usdc" leg) would mint the difference.
    const inputSymbol = getSwapEngineAsset(args.inputAssetId)?.symbol ?? args.inputSymbol
    const outputSymbol = getSwapEngineAsset(args.outputAssetId)?.symbol ?? args.outputSymbol
    if (status === "success") {
      if (!isSwapPairRoutable(args.inputAssetId, args.outputAssetId)) {
        throw codedError("INVALID_SWAP: this pair is not swap-routable.")
      }
      const [inputPrice, outputPrice] = await Promise.all([
        validatedTokenPriceUsd(ctx, inputSymbol, now),
        validatedTokenPriceUsd(ctx, outputSymbol, now),
      ])
      if (!inputPrice || !outputPrice) {
        throw codedError("INVALID_SWAP: both token prices must be current and server-verifiable.")
      }
      const held = await readWalletLiquidBalance(ctx, wallet, args.inputAssetId)
      if (!held || held.amount + 1e-12 < args.inputAmount) {
        throw codedError("INSUFFICIENT_BALANCE: not enough liquid input token for this swap.")
      }
      const math = computeSwapQuoteMath({
        inputAmount: args.inputAmount,
        inputPriceUsd: inputPrice,
        outputPriceUsd: outputPrice,
        slippageBps: args.slippageBps ?? 50,
      })
      executedOutputAmount = math.estimatedOutputAmount
      executedAmountUsd = math.amountUsd
    }
    const executedUsd6 = status === "success" ? String(Math.round(executedAmountUsd * 1_000_000)) : "0"
    const requestedUsd6 = String(Math.round(args.amountUsd * 1_000_000))
    const hash = args.syntheticTxHash ?? `sim-swap-${args.intentId.slice(0, 8)}-${now.toString(36)}`

    const transactionId = await ctx.db.insert("transactions", {
      wallet,
      intentId: args.intentId,
      product: "swap",
      kind: "swap",
      status,
      assetId: args.inputAssetId,
      requestedAmountUsd6: requestedUsd6,
      executedAmountUsd6: executedUsd6,
      amountUsd: status === "success" ? executedAmountUsd : 0,
      swapInputSymbol: inputSymbol,
      swapOutputSymbol: outputSymbol,
      swapInputAmount: args.inputAmount,
      swapOutputAmount: status === "success" ? executedOutputAmount : args.outputAmount,
      swapProvider: args.provider,
      swapQuoteId: args.quoteId,
      swapNetworkFeeUsd: args.networkFeeUsd,
      swapMinOutputAmount: args.minOutputAmount,
      swapPriceImpactPct: args.priceImpactPct,
      swapSlippageBps: args.slippageBps,
      syntheticTxHash: hash,
      simulated,
      at: now,
    })

    if (status === "success") {
      // Apply the SERVER-computed output/USD, not the client's quoted values.
      await applySwapBalanceDelta(
        ctx,
        wallet,
        { ...args, inputSymbol, outputSymbol, outputAmount: executedOutputAmount, amountUsd: executedAmountUsd },
        now,
      )
    }

    return {
      idempotent: false,
      transactionId,
      receipt: { id: transactionId, hash, status, simulated, timestamp: now },
    }
  },
})

/** Durable swap history for a wallet (newest first) — feeds the dashboard activity/receipt. */
export const getWalletSwapTransactions = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const rows = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_product_at", (q) => q.eq("wallet", wallet).eq("product", "swap"))
      .order("desc")
      .take(200)
    return rows.map((row) => ({
      id: row._id,
      intentId: row.intentId ?? null,
      status: row.status,
      inputSymbol: row.swapInputSymbol ?? "",
      outputSymbol: row.swapOutputSymbol ?? "",
      inputAmount: row.swapInputAmount ?? 0,
      outputAmount: row.swapOutputAmount ?? 0,
      amountUsd: row.amountUsd,
      hash: row.syntheticTxHash,
      at: row.at,
    }))
  },
})

/** Merged wallet activity feed: product transactions + sandbox activity, newest first. */
export const getActivity = query({
  args: { wallet: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const limit = Math.min(args.limit ?? 50, 200)
    const txs = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .take(limit)
    const acts = await ctx.db
      .query("sandboxActivity")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .take(limit)
    const transactionItems = txs.map((t) => ({
      source: "transaction" as const,
      id: t._id as string,
      product: t.product as string,
      kind: t.kind,
      status: t.status as string,
      amountUsd: t.amountUsd,
      marketSlug: t.marketSlug ?? null,
      claimedTaskIds: t.claimedTaskIds ?? null,
      hash: t.syntheticTxHash,
      at: t.at,
    }))
    const activityItems = acts.map((a) => {
      const umbrellaKind = a.kind.startsWith("umbrella_") ? a.kind.slice("umbrella_".length) : null
      return {
        source: "sandboxActivity" as const,
        id: a._id as string,
        product: umbrellaKind ? "umbrella" : "onboarding",
        kind: umbrellaKind ?? a.kind,
        status: "success",
        amountUsd: a.amountUsd,
        marketSlug: a.marketSlug ?? null,
        hash: a.syntheticTxHash,
        at: a.at,
      }
    })
    const identity = (item: { hash: string; product: string; kind: string; marketSlug: string | null }) =>
      `${item.hash}\u0000${item.product}\u0000${item.kind}\u0000${item.marketSlug ?? ""}`
    const transactionIdentities = new Set(transactionItems.map(identity))
    const merged = [...transactionItems, ...activityItems.filter((item) => !transactionIdentities.has(identity(item)))]
    merged.sort((x, y) => y.at - x.at)
    return merged.slice(0, limit)
  },
})

/** Resolve one synthetic receipt by hash, restricted to its authenticated owner. */
export const getTransactionByHash = query({
  args: { wallet: v.string(), hash: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    // Indexed point lookup by (wallet, hash), never a full history scan + filter.
    const transaction = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_hash", (q) => q.eq("wallet", wallet).eq("syntheticTxHash", args.hash))
      .first()
    if (transaction) {
      if (
        transaction.product === "borrow" &&
        (transaction.kind === "borrow" || transaction.kind === "repay") &&
        !transaction.assetId &&
        transaction.positionId
      ) {
        const debtRows = await ctx.db
          .query("positionDebt")
          .withIndex("by_position", (q) => q.eq("positionId", transaction.positionId!))
          .collect()
        const assetId = inferDebtAssetIdFromMarketSlug(transaction.marketSlug, debtRows)
        if (assetId) return { ...transaction, assetId }
      }
      return transaction
    }

    return ctx.db
      .query("sandboxActivity")
      .withIndex("by_wallet_hash", (q) => q.eq("wallet", wallet).eq("syntheticTxHash", args.hash))
      .first()
  },
})

/** Wallet-scoped positions with their collateral + debt legs. */
export const getPositions = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const positions = await ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    const out = []
    for (const p of positions) {
      const [collateral, debt] = await Promise.all([
        ctx.db
          .query("positionCollateral")
          .withIndex("by_position", (q) => q.eq("positionId", p._id))
          .collect(),
        ctx.db
          .query("positionDebt")
          .withIndex("by_position", (q) => q.eq("positionId", p._id))
          .collect(),
      ])
      out.push({ ...p, collateral, debt })
    }
    return out
  },
})

/** Balance/position subscription does not depend on the transaction history table. */
async function readSessionBalances(ctx: QueryCtx, wallet: string) {
  const [positions, balances, starterAllocation, rewardClaims] = await Promise.all([
    ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("walletLiquidBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("starterAllocations")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .unique(),
    ctx.db
      .query("sandboxRewardClaims")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
  ])
  // Hydrate collateral/debt in parallel, not in a per-position await loop.
  const hydratedPositions = await Promise.all(
    positions.map(async (position) => {
      const [collateral, debt] = await Promise.all([
        ctx.db
          .query("positionCollateral")
          .withIndex("by_position", (q) => q.eq("positionId", position._id))
          .collect(),
        ctx.db
          .query("positionDebt")
          .withIndex("by_position", (q) => q.eq("positionId", position._id))
          .collect(),
      ])
      return { ...position, collateral, debt }
    }),
  )
  return {
    positions: hydratedPositions,
    balances: balances.map(liquidBalanceView),
    starterAllocation,
    rewardClaims: rewardClaims.map((row) => ({
      rewardPositionId: row.rewardPositionId,
      remainingUsd6: row.remainingUsd6,
    })),
  }
}

async function readSessionTransactions(ctx: QueryCtx, wallet: string) {
  return ctx.db
    .query("transactions")
    .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
    .order("desc")
    .take(500)
}

export const getSessionBalances = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => readSessionBalances(ctx, await requireSandboxWallet(ctx, args.wallet)),
})

export const getSessionTransactions = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => readSessionTransactions(ctx, await requireSandboxWallet(ctx, args.wallet)),
})

/** Compatibility read for callers that need the complete atomic payload. */
export const getSessionState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const [balances, transactions] = await Promise.all([
      readSessionBalances(ctx, wallet),
      readSessionTransactions(ctx, wallet),
    ])
    return { ...balances, transactions }
  },
})

/** Full wallet-scoped portfolio read model plus the catalog identity rows it references. */
export const getPortfolioPageState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const positions = await ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()

    // Hydrate collateral/debt in parallel, not in a per-position await loop.
    const hydratedPositions = await Promise.all(
      positions.map(async (position) => {
        const [collateral, debt] = await Promise.all([
          ctx.db
            .query("positionCollateral")
            .withIndex("by_position", (q) => q.eq("positionId", position._id))
            .collect(),
          ctx.db
            .query("positionDebt")
            .withIndex("by_position", (q) => q.eq("positionId", position._id))
            .collect(),
        ])
        return { ...position, collateral, debt }
      }),
    )

    // Fetch ONLY the catalog rows this wallet's positions reference, not the whole
    // 173-market catalog per subscriber. Borrow collateral joins `pools`; lend/multiply
    // join `markets`.
    const poolSlugs = new Set<string>()
    const marketRefs = new Map<string, { scope: "lend" | "multiply"; slug: string }>()
    for (const position of hydratedPositions) {
      if (position.product === "borrow") {
        for (const c of position.collateral) poolSlugs.add(c.marketSlug)
      } else if (position.product === "lend" || position.product === "multiply") {
        marketRefs.set(`${position.product}:${position.marketSlug}`, {
          scope: position.product,
          slug: position.marketSlug,
        })
      }
    }

    const [transactions, snapshotRows, current, risk, rewards, balances, starterAllocation, poolRows, marketRows] =
      await Promise.all([
        ctx.db
          .query("transactions")
          .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
          .order("desc")
          .take(500),
        ctx.db
          .query("portfolioSnapshots")
          .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
          .order("desc")
          .take(MAX_PORTFOLIO_HISTORY_ROWS),
        latestPortfolioCurrent(ctx, wallet),
        ctx.db
          .query("riskSnapshots")
          .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
          .order("desc")
          .first(),
        ctx.db
          .query("sandboxRewards")
          .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
          .unique(),
        ctx.db
          .query("walletLiquidBalances")
          .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
          .collect(),
        ctx.db
          .query("starterAllocations")
          .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
          .unique(),
        Promise.all(
          [...poolSlugs].map((slug) =>
            ctx.db
              .query("pools")
              .withIndex("by_slug", (q) => q.eq("slug", slug))
              .unique(),
          ),
        ),
        Promise.all(
          [...marketRefs.values()].map((ref) =>
            ctx.db
              .query("markets")
              .withIndex("by_scope_slug", (q) => q.eq("scope", ref.scope).eq("slug", ref.slug))
              .unique(),
          ),
        ),
      ])
    const pools = poolRows.filter((row): row is NonNullable<typeof row> => row !== null)
    const markets = marketRows.filter((row): row is NonNullable<typeof row> => row !== null)
    const snapshots = snapshotRows.reverse()
    // portfolioCurrent and portfolioSnapshots carry identical value fields; only the branded
    // _id differs, so appending the live "current" point casts past that nominal mismatch.
    if (current && snapshots.at(-1)?.at !== current.at) snapshots.push(current as unknown as (typeof snapshots)[number])
    return {
      positions: hydratedPositions,
      transactions,
      snapshots,
      risk,
      pools,
      markets,
      rewards,
      balances: balances.map(liquidBalanceView),
      starterAllocation,
    }
  },
})

/** Wallet-scoped portfolio: the snapshot time series + position summary. */
/**
 * Historical health-factor series. `riskSnapshots` are written on every account-touching
 * action, so resolution follows action density, not a fixed cadence. Values ship as
 * decimal-WAD strings; the dashboard converts WAD → hf once and skips null rows so a
 * debt-free window does not render as 0.
 */
export const getRiskSeries = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const rows = await ctx.db
      .query("riskSnapshots")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .take(MAX_PORTFOLIO_HISTORY_ROWS)
    return rows
      .reverse()
      .map((row) => ({ at: row.at, healthFactorWad: row.healthFactorWad, trigger: row.trigger ?? null }))
  },
})

export const getPortfolio = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const [snapshotRows, current, positions, walletCollateral] = await Promise.all([
      ctx.db
        .query("portfolioSnapshots")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
        .order("desc")
        .take(MAX_PORTFOLIO_HISTORY_ROWS),
      latestPortfolioCurrent(ctx, wallet),
      ctx.db
        .query("positions")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletCollateralPositions")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
    ])
    const snapshots = snapshotRows.reverse()
    const latest = current ?? snapshots.at(-1) ?? null
    // portfolioCurrent and portfolioSnapshots carry identical value fields; only the branded
    // _id differs, so appending the live "current" point casts past that nominal mismatch.
    if (current && snapshots.at(-1)?.at !== current.at) snapshots.push(current as unknown as (typeof snapshots)[number])

    const netApyPct = await computePortfolioNetApyPct(ctx, positions, walletCollateral)

    return {
      snapshots,
      latest,
      netApyPct,
      openPositions: positions.filter((p) => p.status === "open").length,
      positionCount: positions.length,
    }
  },
})

/**
 * Blended portfolio Net APY, value-weighted by NET equity across lend (`supplyApyPct`),
 * multiply (`netApyPct`) and borrow (collateral pair APR from `pools`); home-seed borrow
 * collateral with no live `positions` row folds in on the same basis. UMBRELLA IS EXCLUDED.
 * Computed at read time, so it always reflects current rates rather than a stored field.
 */
export async function computePortfolioNetApyPct(
  // Only reads `ctx.db`, so it accepts any read context (Ask AI passes a turn-scoped one).
  ctx: Pick<QueryCtx, "db">,
  positions: Array<Doc<"positions">>,
  walletCollateral: Array<Doc<"walletCollateralPositions">>,
): Promise<number> {
  const open = positions.filter((position) => position.status === "open")
  const liveBorrowSlugs = new Set(
    open.filter((position) => position.product === "borrow").map((position) => position.marketSlug),
  )

  // Fetch pair APR for every borrow slug we need (live positions + non-shadowed seed collateral).
  const borrowSlugs = [
    ...new Set([
      ...open.filter((position) => position.product === "borrow").map((position) => position.marketSlug),
      ...walletCollateral.filter((row) => !liveBorrowSlugs.has(row.marketId)).map((row) => row.marketId),
    ]),
  ].filter(Boolean)
  const borrowPools = await Promise.all(
    borrowSlugs.map((slug) =>
      ctx.db
        .query("pools")
        .withIndex("by_slug", (q) => q.eq("slug", slug))
        .unique(),
    ),
  )
  const pairAprBySlug = new Map(
    borrowPools
      .filter((pool): pool is NonNullable<typeof pool> => pool !== null)
      .map((pool) => [pool.slug, pool.pairAprPct] as const),
  )

  // Weight by NET equity (collateral − debt), matching how Net Value is built, so the two
  // headlines agree. UMBRELLA must not contribute to the global Net APY.
  const legs: Array<{ weight: number; rate: number }> = []
  for (const position of open) {
    if (position.product === "lend") {
      const base = usd6Number(position.suppliedUsd6)
      if (base > 0) legs.push({ weight: base, rate: position.supplyApyPct ?? 0 })
    } else if (position.product === "multiply") {
      const base = (position.collateralValueUsd ?? 0) - (position.debtValueUsd ?? 0)
      if (base > 0) {
        // Recompute from market economics: the persisted `netApyPct` is 0 on most loops and a
        // fraction on the rest. Skip an unknown market rather than blending a fake 0%.
        const rate = catalogMultiplyNetApyPct(
          position.marketSlug,
          position.collateralValueUsd ?? 0,
          position.debtValueUsd ?? 0,
        )
        if (rate != null) legs.push({ weight: base, rate })
      }
    } else if (position.product === "borrow") {
      const base = usd6Number(position.collateralValueUsd6) - usd6Number(position.debtValueUsd6)
      const rate = pairAprBySlug.get(position.marketSlug)
      // Skip an unknown pool rate rather than blending a fake 0%, which would add a large
      // zero-rate weight and crush the blend.
      if (base > 0 && rate != null) legs.push({ weight: base, rate })
    }
    // product === "umbrella": intentionally skipped.
  }
  // Home-seed borrow collateral with no live position, only when its pool rate resolves
  // (unmatched seed slugs must not drag the blend toward 0%).
  for (const row of walletCollateral) {
    if (liveBorrowSlugs.has(row.marketId)) continue
    const rate = pairAprBySlug.get(row.marketId)
    if (row.collateralUsd > 0 && rate != null) legs.push({ weight: row.collateralUsd, rate })
  }

  const totalWeight = legs.reduce((sum, leg) => sum + leg.weight, 0)
  if (totalWeight <= 0) return 0
  return legs.reduce((sum, leg) => sum + leg.weight * leg.rate, 0) / totalWeight
}

/**
 * Write the first portfolioCurrent/snapshot when home seeds + liquid balances exist but no
 * action has fired appendPortfolioSnapshot, so the chart reads Convex history, not a
 * synthetic series.
 */
export const ensurePortfolioSnapshot = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const current = await latestPortfolioCurrent(ctx, wallet)
    if (current) return { wrote: false as const }
    await appendPortfolioSnapshot(ctx, wallet, Date.now())
    return { wrote: true as const }
  },
})

/** Latest risk/health snapshot for the wallet (null if none recorded yet). */
export const getRisk = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    return ctx.db
      .query("riskSnapshots")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .first()
  },
})
