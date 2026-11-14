import { codedError } from "../codedError"
import { v } from "convex/values"
import type { MutationCtx, QueryCtx } from "../_generated/server"
import { internalMutation, internalQuery, mutation, query } from "../_generated/server"
import type { Doc, Id } from "../_generated/dataModel"
import { requireSandboxWallet } from "./auth"
import { readWalletLiquidBalance, upsertLiquidWalletBalance } from "../wallet/balances"
import { validatedTokenPriceUsd } from "./oraclePrice"

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60
const COOLDOWN_MS = 20 * 24 * 60 * 60 * 1000
const WITHDRAWAL_WINDOW_MS = 2 * 24 * 60 * 60 * 1000
export const MAX_UMBRELLA_TX_PER_HOUR = 200
const MAX_UMBRELLA_INTENT_LENGTH = 200

const umbrellaMarketId = v.union(v.literal("gho"), v.literal("usdc"), v.literal("usdt"), v.literal("weth"))
const umbrellaActionKind = v.union(
  v.literal("stake"),
  v.literal("claim"),
  v.literal("startCooldown"),
  v.literal("unstake"),
)

const UMBRELLA_MARKETS = {
  gho: {
    id: "gho",
    asset: "Stake GHO",
    symbol: "GHO",
    hubLabel: "Stable Hub",
    coverage: "GHO deficits",
    totalStakedUsd: 25_000_000,
    apy: 6.4,
    rewardApy: 6.4,
    baseApy: 0,
    liquidationRecaptureApy: 2.25,
    incentiveApy: 4.15,
    priceUsd: 1,
    targetCoverageUsd: 22_000_000,
    localDeductibleUsd: 250_000,
    hubTailTargetUsd: 30_000_000,
    coverageMode: "Live Umbrella",
    currentDeficitUsd: 146,
    deficitOffsetUsd: 1_000_000,
    amountInCooldownUsd: 2_500_000,
  },
  usdc: {
    id: "usdc",
    asset: "Stake USDC",
    symbol: "USDC",
    hubLabel: "Stable Hub",
    coverage: "USDC deficits",
    totalStakedUsd: 12_000_000,
    apy: 4.84,
    rewardApy: 3.12,
    baseApy: 1.72,
    liquidationRecaptureApy: 1.25,
    incentiveApy: 1.87,
    priceUsd: 1,
    targetCoverageUsd: 10_000_000,
    localDeductibleUsd: 100_000,
    hubTailTargetUsd: 15_000_000,
    coverageMode: "Live Umbrella",
    currentDeficitUsd: 51_371,
    deficitOffsetUsd: 500_000,
    amountInCooldownUsd: 1_150_000,
  },
  usdt: {
    id: "usdt",
    asset: "Stake USDT",
    symbol: "USDT",
    hubLabel: "Correlated Hub",
    coverage: "USDT deficits",
    totalStakedUsd: 11_000_000,
    apy: 4.19,
    rewardApy: 2.85,
    baseApy: 1.34,
    liquidationRecaptureApy: 1.15,
    incentiveApy: 1.7,
    priceUsd: 1,
    targetCoverageUsd: 9_500_000,
    localDeductibleUsd: 100_000,
    hubTailTargetUsd: 14_000_000,
    coverageMode: "Live Umbrella",
    currentDeficitUsd: 32_420,
    deficitOffsetUsd: 400_000,
    amountInCooldownUsd: 980_000,
  },
  weth: {
    id: "weth",
    asset: "Stake WETH",
    symbol: "WETH",
    hubLabel: "Correlated Hub",
    coverage: "WETH deficits",
    totalStakedUsd: 7_000_000,
    apy: 5.05,
    rewardApy: 2.4,
    baseApy: 2.65,
    liquidationRecaptureApy: 1.2,
    incentiveApy: 1.2,
    // MUST equal the app-wide baseline (app/lib/prices/sandbox-baseline-prices.ts → WETH:1934).
    // Convex cannot import app/, so this is hand-synced; a past drift to 2240 valued WETH ~16%
    // higher in Umbrella than everywhere else.
    priceUsd: 1934,
    targetCoverageUsd: 6_250_000,
    localDeductibleUsd: 150_000,
    hubTailTargetUsd: 10_000_000,
    coverageMode: "Live Umbrella",
    currentDeficitUsd: 52_973,
    deficitOffsetUsd: 250_000,
    amountInCooldownUsd: 520_000,
  },
} as const

type UmbrellaMarketId = keyof typeof UMBRELLA_MARKETS

/**
 * Single source of truth for the onboarding wallet seed's per-token prices — onboarding and
 * ensureTestWalletFixtures must reference these, never hard-code their own. Consistency with
 * the app fixture is enforced by convex/__tests__/price-copy-drift.test.ts.
 */
export const UMBRELLA_ONBOARDING_TOKEN_PRICES: Record<UmbrellaMarketId, number> = {
  gho: UMBRELLA_MARKETS.gho.priceUsd,
  usdc: UMBRELLA_MARKETS.usdc.priceUsd,
  usdt: UMBRELLA_MARKETS.usdt.priceUsd,
  weth: UMBRELLA_MARKETS.weth.priceUsd,
}

function usd6(value: number) {
  return String(Math.max(0, Math.round(value * 1_000_000)))
}

function numberFromUsd6(value?: string) {
  return Number(BigInt(value ?? "0")) / 1_000_000
}

function tokenAmountFromUsd(usd: number, priceUsd: number) {
  return priceUsd > 0 ? usd / priceUsd : usd
}

/**
 * Umbrella principal and cooldown tranches (`suppliedUsd6`, `cooldownAmountUsd6`, tranche
 * `amountUsd6`) are a TOKEN ledger kept in USD6 at the market's fixed reference price
 * (`UMBRELLA_MARKETS[m].priceUsd`; $1 for the stables). Converting at the LIVE price instead
 * made stake and unstake disagree for WETH: 1 WETH staked at $2,000 could only be unstaked as
 * 0.5 WETH after WETH doubled, and as 2 WETH after it halved. Live prices are only for display.
 */
function ledgerUsdFromTokens(marketId: UmbrellaMarketId, amount: number) {
  return amount * UMBRELLA_MARKETS[marketId].priceUsd
}

function tokensFromLedgerUsd(marketId: UmbrellaMarketId, ledgerUsd: number) {
  return tokenAmountFromUsd(ledgerUsd, UMBRELLA_MARKETS[marketId].priceUsd)
}

/** Live USD value of a ledger amount, for display. */
function liveUsdFromLedgerUsd(marketId: UmbrellaMarketId, ledgerUsd: number, livePriceUsd: number) {
  return tokensFromLedgerUsd(marketId, ledgerUsd) * livePriceUsd
}

function rewardAccruedUsd(position: Doc<"positions">, now: number) {
  if (position.product !== "umbrella" || position.status !== "open") return 0
  const market = UMBRELLA_MARKETS[position.marketSlug as UmbrellaMarketId]
  if (!market) return 0
  const principalUsd = numberFromUsd6(position.suppliedUsd6)
  // `rewardCheckpointAt` is the accrual clock, NOT `lastUpdatedAt` — every non-checkpointing
  // patch (balance sync, deficit sim, dev advance) touches the latter, which silently resets
  // rewards. Falls back to lastUpdatedAt only for rows predating the field.
  const checkpoint = position.rewardCheckpointAt ?? position.lastUpdatedAt
  const elapsedSeconds = Math.max(0, (now - checkpoint) / 1000)
  return principalUsd * (market.rewardApy / 100) * (elapsedSeconds / SECONDS_PER_YEAR)
}

/**
 * Umbrella liquid-balance writer. `walletLiquidBalances` is the spendable source of truth and
 * `walletBalances` its aggregate projection; both MUST move by the same amount in the same
 * mutation, so umbrella's post-stake balance is indistinguishable from any other product's.
 */
async function upsertLiquidBalance(
  ctx: MutationCtx,
  wallet: string,
  marketId: UmbrellaMarketId,
  amount: number,
  now: number,
  priceUsd: number = UMBRELLA_MARKETS[marketId].priceUsd,
) {
  const market = UMBRELLA_MARKETS[marketId]
  const valueUsd = amount * priceUsd
  await upsertLiquidWalletBalance(ctx, {
    wallet,
    assetId: marketId,
    symbol: market.symbol,
    amount,
    valueUsd,
    updatedAt: now,
  })
}

async function readLiquidBalance(ctx: QueryCtx | MutationCtx, wallet: string, marketId: UmbrellaMarketId) {
  const row = await readWalletLiquidBalance(ctx, wallet, marketId)
  return row?.amount ?? 0
}

async function readUmbrellaPosition(ctx: QueryCtx | MutationCtx, wallet: string, marketId: UmbrellaMarketId) {
  return await ctx.db
    .query("positions")
    .withIndex("by_wallet_product_market", (q) =>
      q.eq("wallet", wallet).eq("product", "umbrella").eq("marketSlug", marketId),
    )
    .unique()
}

/**
 * Every active (non-"consumed") tranche for a (wallet, market). Callers re-derive status
 * against `now`; the persisted `status` only exists to filter consumed rows without a scan.
 */
async function listActiveTranches(ctx: QueryCtx | MutationCtx, wallet: string, marketId: UmbrellaMarketId) {
  const [cooling, ready, expired] = await Promise.all([
    ctx.db
      .query("umbrellaCooldownTranches")
      .withIndex("by_wallet_market_status", (q) =>
        q.eq("wallet", wallet).eq("marketId", marketId).eq("status", "cooling"),
      )
      .collect(),
    ctx.db
      .query("umbrellaCooldownTranches")
      .withIndex("by_wallet_market_status", (q) =>
        q.eq("wallet", wallet).eq("marketId", marketId).eq("status", "ready"),
      )
      .collect(),
    ctx.db
      .query("umbrellaCooldownTranches")
      .withIndex("by_wallet_market_status", (q) =>
        q.eq("wallet", wallet).eq("marketId", marketId).eq("status", "expired"),
      )
      .collect(),
  ])
  return [...cooling, ...ready, ...expired]
}

/** Live status from `now` vs endsAt / windowEndsAt. Never returns "consumed" — callers
 *  pre-filter those. */
function deriveTrancheStatus(tranche: Doc<"umbrellaCooldownTranches">, now: number): "cooling" | "ready" | "expired" {
  if (now < tranche.endsAt) return "cooling"
  if (now < tranche.windowEndsAt) return "ready"
  return "expired"
}

/**
 * Recompute the `positions.cooldown*` rollups from the active tranches. MUST run after every
 * startCooldown / unstake / slash so aggregate readers stay coherent.
 */
async function recomputePositionAggregate(
  ctx: MutationCtx,
  wallet: string,
  marketId: UmbrellaMarketId,
  positionId: Id<"positions">,
  now: number,
) {
  const active = await listActiveTranches(ctx, wallet, marketId)
  let totalUsd6 = 0n
  let minStartedAt: number | undefined
  let minEndsAt: number | undefined
  let minWindowEndsAt: number | undefined
  for (const tranche of active) {
    totalUsd6 += BigInt(tranche.amountUsd6)
    if (minStartedAt === undefined || tranche.startedAt < minStartedAt) minStartedAt = tranche.startedAt
    if (minEndsAt === undefined || tranche.endsAt < minEndsAt) minEndsAt = tranche.endsAt
    if (minWindowEndsAt === undefined || tranche.windowEndsAt < minWindowEndsAt) minWindowEndsAt = tranche.windowEndsAt
  }
  await ctx.db.patch(positionId, {
    cooldownAmountUsd6: totalUsd6.toString(),
    cooldownStartedAt: minStartedAt,
    cooldownEndsAt: minEndsAt,
    withdrawalWindowEndsAt: minWindowEndsAt,
    lastUpdatedAt: now,
  })
}

type UmbrellaAmounts = { suppliedUsd6?: string; cooldownAmountUsd6?: string } | null

/** Σ staked / cooldown usd6 over every wallet's position in one market (a full scan). */
async function scanUmbrellaMarketTotals(ctx: QueryCtx | MutationCtx, marketId: UmbrellaMarketId) {
  const rows = await ctx.db
    .query("positions")
    .withIndex("by_product_market", (q) => q.eq("product", "umbrella").eq("marketSlug", marketId))
    .collect()
  let staked = 0n
  let cooldown = 0n
  for (const row of rows) {
    staked += BigInt(row.suppliedUsd6 ?? "0")
    cooldown += BigInt(row.cooldownAmountUsd6 ?? "0")
  }
  return { staked, cooldown }
}

async function readUmbrellaMarketTotals(ctx: QueryCtx | MutationCtx, marketId: UmbrellaMarketId) {
  return ctx.db
    .query("umbrellaMarketTotals")
    .withIndex("by_market", (q) => q.eq("marketId", marketId))
    .unique()
}

/**
 * Keep a market's totals in step with one position write, in O(1). Call AFTER the write with the
 * position's amounts before and after it. The first write to a market since the totals table
 * existed seeds its row from a one-time scan, which already includes this write.
 */
async function applyUmbrellaTotalsDelta(
  ctx: MutationCtx,
  marketId: UmbrellaMarketId,
  before: UmbrellaAmounts,
  after: UmbrellaAmounts,
  now: number,
) {
  const stakedDelta = BigInt(after?.suppliedUsd6 ?? "0") - BigInt(before?.suppliedUsd6 ?? "0")
  const cooldownDelta = BigInt(after?.cooldownAmountUsd6 ?? "0") - BigInt(before?.cooldownAmountUsd6 ?? "0")
  if (stakedDelta === 0n && cooldownDelta === 0n) return
  const row = await readUmbrellaMarketTotals(ctx, marketId)
  if (!row) {
    const totals = await scanUmbrellaMarketTotals(ctx, marketId)
    await ctx.db.insert("umbrellaMarketTotals", {
      marketId,
      stakedUsd6: totals.staked.toString(),
      cooldownUsd6: totals.cooldown.toString(),
      updatedAt: now,
    })
    return
  }
  const staked = BigInt(row.stakedUsd6) + stakedDelta
  const cooldown = BigInt(row.cooldownUsd6) + cooldownDelta
  await ctx.db.patch(row._id, {
    stakedUsd6: (staked > 0n ? staked : 0n).toString(),
    cooldownUsd6: (cooldown > 0n ? cooldown : 0n).toString(),
    updatedAt: now,
  })
}

/** Recompute every market's totals from the positions (deploy-time seed / drift repair). */
/**
 * One-off migration for WETH stakes written before the ledger used the reference price: their
 * `suppliedUsd6` holds USD at the stake-time LIVE price. The plan proposes the token count that
 * USD bought, at the WETH daily close on the stake day (`tokenPricesHistory`), falling back to
 * the reference price. Read-only; review it, then pass the rows to the apply mutation.
 */
export const planUmbrellaWethLedgerMigration = internalQuery({
  args: {},
  handler: async (ctx) => {
    const positions = await ctx.db
      .query("positions")
      .withIndex("by_product_market", (q) => q.eq("product", "umbrella").eq("marketSlug", "weth"))
      .collect()
    const plan = []
    for (const position of positions) {
      if (position.status !== "open") continue
      const day = new Date(position.openedAt).toISOString().slice(0, 10)
      const close = await ctx.db
        .query("tokenPricesHistory")
        .withIndex("by_symbol_day", (q) => q.eq("symbol", "weth").lte("day", day))
        .order("desc")
        .first()
      const stakePriceUsd = close?.priceUsd ?? UMBRELLA_MARKETS.weth.priceUsd
      const suppliedUsd = numberFromUsd6(position.suppliedUsd6)
      const tokens = suppliedUsd / stakePriceUsd
      plan.push({
        positionId: position._id,
        expectedSuppliedUsd6: position.suppliedUsd6 ?? "0",
        stakeDay: close?.day ?? null,
        stakePriceUsd,
        tokens,
        nextSuppliedUsd6: usd6(ledgerUsdFromTokens("weth", tokens)),
      })
    }
    return plan
  },
})

/**
 * Applies reviewed rows from `planUmbrellaWethLedgerMigration`. Each row patches only while the
 * position still holds `expectedSuppliedUsd6`, so a re-run is a no-op. Refuses positions with
 * active cooldown tranches (none existed when this was written); those need a tranche-aware pass.
 */
export const applyUmbrellaWethLedgerMigration = internalMutation({
  args: {
    rows: v.array(v.object({ positionId: v.id("positions"), expectedSuppliedUsd6: v.string(), tokens: v.number() })),
  },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    let migrated = 0
    let skipped = 0
    for (const row of rows) {
      const position = await ctx.db.get(row.positionId)
      if (!position || position.product !== "umbrella" || position.marketSlug !== "weth") {
        throw new Error(`not a WETH umbrella position: ${row.positionId}`)
      }
      if (position.suppliedUsd6 !== row.expectedSuppliedUsd6) {
        skipped++
        continue
      }
      if (!(row.tokens > 0) || !Number.isFinite(row.tokens)) throw new Error(`invalid tokens for ${row.positionId}`)
      const tranches = await listActiveTranches(ctx, position.wallet, "weth")
      if (tranches.some((tranche) => BigInt(tranche.amountUsd6) > 0n)) {
        throw new Error(`position ${row.positionId} has active cooldown tranches`)
      }
      await ctx.db.patch(position._id, {
        suppliedUsd6: usd6(ledgerUsdFromTokens("weth", row.tokens)),
        revision: (position.revision ?? 0) + 1,
      })
      await applyUmbrellaTotalsDelta(ctx, "weth", position, await ctx.db.get(position._id), now)
      migrated++
    }
    return { migrated, skipped }
  },
})

export const rebuildUmbrellaMarketTotals = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now()
    const markets = Object.keys(UMBRELLA_MARKETS) as UmbrellaMarketId[]
    for (const marketId of markets) {
      const totals = await scanUmbrellaMarketTotals(ctx, marketId)
      const next = { stakedUsd6: totals.staked.toString(), cooldownUsd6: totals.cooldown.toString(), updatedAt: now }
      const row = await readUmbrellaMarketTotals(ctx, marketId)
      if (row) await ctx.db.patch(row._id, next)
      else await ctx.db.insert("umbrellaMarketTotals", { marketId, ...next })
    }
    return { markets: markets.length }
  },
})

/**
 * Live umbrella market-state overlay (deficit + slash counters) from `umbrellaMarketState`,
 * falling back to the frozen catalog when a market has no row yet.
 */
async function readUmbrellaMarketOverlay(ctx: QueryCtx | MutationCtx, marketId: UmbrellaMarketId) {
  const row = await ctx.db
    .query("umbrellaMarketState")
    .withIndex("by_market", (q) => q.eq("marketId", marketId))
    .unique()
  const catalog = UMBRELLA_MARKETS[marketId]
  return {
    row,
    currentDeficitUsd: row?.currentDeficitUsd ?? catalog.currentDeficitUsd,
    deficitOffsetUsd: row?.deficitOffsetUsd ?? catalog.deficitOffsetUsd,
    totalSlashedUsd: row?.totalSlashedUsd ?? 0,
  }
}

/**
 * Dev-controls guard for the time-warp / stress mutations (`simulateDeficit`,
 * `simulateSlash`, `dev.advanceCooldown`). Opt-in via `SANDBOX_DEV_CONTROLS` in `.env.local`,
 * with a production FLOOR: a production deployment fails closed even if the flag is set,
 * mirroring `isProductionBuild()` in app/lib/test-mode.ts.
 */
export function assertSandboxDevControlsEnabled() {
  if (process.env.NODE_ENV === "production") throw new Error("DEV_CONTROLS_DISABLED")
  if (process.env.SANDBOX_DEV_CONTROLS !== "true") throw new Error("DEV_CONTROLS_DISABLED")
}

export const getSessionState = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const now = Date.now()
    const marketIds = Object.keys(UMBRELLA_MARKETS) as UmbrellaMarketId[]
    const [balances, positions, transactions, aggregatesPerMarket, overlays, tranchesByWallet, priceRows] =
      await Promise.all([
        Promise.all(marketIds.map((marketId) => readLiquidBalance(ctx, authed, marketId))),
        ctx.db
          .query("positions")
          .withIndex("by_wallet_product", (q) => q.eq("wallet", authed).eq("product", "umbrella"))
          .collect(),
        ctx.db
          .query("transactions")
          .withIndex("by_wallet_product_at", (q) => q.eq("wallet", authed).eq("product", "umbrella"))
          .order("desc")
          // Display history only; same cap as the session transaction feed.
          .take(500),
        // Every wallet's staked / cooldown USD per market, so Coverage and Amount-in-cooldown
        // move with activity, added on top of the catalog baseline (which stands for pre-existing
        // external liquidity). Read from the running totals row: scanning all wallets' positions
        // here made every subscriber's read grow with the user count and re-run on any stake.
        // A market with no totals row yet (no write since the table existed) falls back to the scan.
        Promise.all(
          marketIds.map(async (marketId) => {
            const totals = await readUmbrellaMarketTotals(ctx, marketId)
            const sums = totals
              ? { staked: BigInt(totals.stakedUsd6), cooldown: BigInt(totals.cooldownUsd6) }
              : await scanUmbrellaMarketTotals(ctx, marketId)
            return {
              marketId,
              stakedUsd: numberFromUsd6(sums.staked.toString()),
              cooldownUsd: numberFromUsd6(sums.cooldown.toString()),
            }
          }),
        ),
        Promise.all(marketIds.map((marketId) => readUmbrellaMarketOverlay(ctx, marketId))),
        // One by_wallet index read, folded per market below — cheaper than per-position reads.
        ctx.db
          .query("umbrellaCooldownTranches")
          .withIndex("by_wallet", (q) => q.eq("wallet", authed))
          .collect(),
        ctx.db.query("tokenPrices").collect(),
      ])
    const convexPrices = new Map(
      priceRows
        .filter(
          (row) =>
            Number.isFinite(row.priceUsd) &&
            row.priceUsd > 0 &&
            row.status !== "invalid" &&
            (row.confidence == null || row.confidence >= 0.8),
        )
        .map((row) => [row.symbol.toLowerCase(), row.priceUsd]),
    )
    // The catalog holds Target / APY / priceUsd as static config; totalStakedUsd /
    // amountInCooldownUsd come from the live aggregate, and the deficit/slash counters from
    // the umbrellaMarketState overlay (catalog fallback).
    const liveMarkets = Object.fromEntries(
      marketIds.map((marketId, index) => {
        const base = UMBRELLA_MARKETS[marketId]
        const agg = aggregatesPerMarket.find((row) => row.marketId === marketId)
        const livePriceUsd = convexPrices.get(base.symbol.toLowerCase()) ?? base.priceUsd
        const overlay = overlays[index]
        // No negative-fold guard needed: usd6() clamps every write to >= 0, so the summed
        // aggregates are non-negative by construction and `base + agg` >= base >= 0.
        return [
          marketId,
          {
            ...base,
            priceUsd: livePriceUsd,
            // The aggregate is token ledger at the reference price; the baselines are USD, so add
            // it at the live price (a 1 WETH stake at $2,752 adds $2,752, not the $1,934 reference).
            totalStakedUsd: base.totalStakedUsd + liveUsdFromLedgerUsd(marketId, agg?.stakedUsd ?? 0, livePriceUsd),
            amountInCooldownUsd:
              base.amountInCooldownUsd + liveUsdFromLedgerUsd(marketId, agg?.cooldownUsd ?? 0, livePriceUsd),
            currentDeficitUsd: overlay.currentDeficitUsd,
            deficitOffsetUsd: overlay.deficitOffsetUsd,
            totalSlashedUsd: overlay.totalSlashedUsd,
          },
        ]
      }),
    ) as Record<UmbrellaMarketId, (typeof UMBRELLA_MARKETS)[UmbrellaMarketId] & { totalSlashedUsd: number }>
    return {
      walletId: authed,
      markets: liveMarkets,
      walletBalances: Object.fromEntries(marketIds.map((marketId, index) => [marketId, balances[index] ?? 0])),
      positions: positions.map((position) => {
        const marketId = position.marketSlug as UmbrellaMarketId
        // Fold this wallet's active tranches into the aggregate + the UI list; consumed
        // tranches never surface.
        const positionTranches = tranchesByWallet
          .filter((row) => row.positionId === position._id && row.status !== "consumed")
          .map((row) => ({
            _id: row._id,
            amountUsd: liveUsdFromLedgerUsd(marketId, numberFromUsd6(row.amountUsd6), liveMarkets[marketId].priceUsd),
            startedAt: row.startedAt,
            endsAt: row.endsAt,
            windowEndsAt: row.windowEndsAt,
            status: deriveTrancheStatus(row, now),
          }))
          .sort((a, b) => a.endsAt - b.endsAt)
        const anyExpiredWithCooling = positionTranches.some((t) => t.status === "expired" && t.amountUsd > 0)
        const withdrawalWindowExpired = anyExpiredWithCooling
        // Rollups come from the tranches (source of truth); the stored aggregate is only a
        // fallback for pre-tranche seed rows.
        const trancheTotalUsd = positionTranches.reduce((sum, t) => sum + t.amountUsd, 0)
        const cooldownUsd =
          positionTranches.length > 0
            ? trancheTotalUsd
            : liveUsdFromLedgerUsd(
                marketId,
                numberFromUsd6(position.cooldownAmountUsd6),
                liveMarkets[marketId].priceUsd,
              )
        const activeEndsCandidates = positionTranches.filter((t) => t.status !== "expired").map((t) => t.endsAt)
        const readyWindowCandidates = positionTranches.filter((t) => t.status === "ready").map((t) => t.windowEndsAt)
        const cooldownEndsAt =
          positionTranches.length > 0
            ? activeEndsCandidates.length > 0
              ? Math.min(...activeEndsCandidates)
              : positionTranches[0]?.endsAt
            : position.cooldownEndsAt
        const withdrawalWindowEndsAt =
          positionTranches.length > 0
            ? readyWindowCandidates.length > 0
              ? Math.min(...readyWindowCandidates)
              : positionTranches[0]?.windowEndsAt
            : position.withdrawalWindowEndsAt
        const cooldownStartedAt =
          positionTranches.length > 0
            ? Math.min(...positionTranches.map((t) => t.startedAt))
            : position.cooldownStartedAt
        return {
          _id: position._id,
          marketId,
          suppliedUsd: liveUsdFromLedgerUsd(
            marketId,
            numberFromUsd6(position.suppliedUsd6),
            liveMarkets[marketId].priceUsd,
          ),
          amount: tokensFromLedgerUsd(marketId, numberFromUsd6(position.suppliedUsd6)),
          pendingRewardsUsd: numberFromUsd6(position.earnedUsd6) + rewardAccruedUsd(position, now),
          claimedRewardsUsd: numberFromUsd6(position.claimedRewardsUsd6),
          cooldownUsd,
          cooldownStartedAt,
          cooldownEndsAt,
          withdrawalWindowEndsAt,
          withdrawalWindowExpired,
          slashedAmountUsd: numberFromUsd6(position.slashedAmountUsd6),
          status: position.status,
          lastUpdatedAt: position.lastUpdatedAt,
          tranches: positionTranches,
        }
      }),
      transactions: transactions.map((row) => ({
        id: String(row._id),
        intentId: row.intentId,
        kind: row.kind,
        marketId: row.marketSlug,
        amountUsd: row.amountUsd,
        syntheticTxHash: row.syntheticTxHash,
        status: row.status,
        at: row.at,
      })),
    }
  },
})

export const recordAction = mutation({
  args: {
    wallet: v.string(),
    intentId: v.string(),
    kind: umbrellaActionKind,
    marketId: umbrellaMarketId,
    amount: v.number(),
  },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    if (!args.intentId || args.intentId.length > MAX_UMBRELLA_INTENT_LENGTH) throw codedError("INVALID_INTENT_ID")
    const existingTx = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_intent", (q) => q.eq("wallet", wallet).eq("intentId", args.intentId))
      .unique()
    if (existingTx) return { idempotent: true, receipt: existingTx }

    const now = Date.now()
    const recent = await ctx.db
      .query("transactions")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet).gte("at", now - 60 * 60 * 1000))
      .take(MAX_UMBRELLA_TX_PER_HOUR)
    if (recent.length >= MAX_UMBRELLA_TX_PER_HOUR) {
      throw codedError(`RATE_LIMITED: more than ${MAX_UMBRELLA_TX_PER_HOUR} wallet transactions in the last hour.`)
    }

    const market = UMBRELLA_MARKETS[args.marketId]
    if (!Number.isFinite(args.amount) || args.amount < 0) throw codedError("INVALID_AMOUNT")
    const amount = Math.max(0, args.amount)
    if (args.kind !== "claim" && amount <= 0) throw codedError("INVALID_AMOUNT")
    const livePriceUsd = args.kind === "claim" ? null : await validatedTokenPriceUsd(ctx, market.symbol, now)
    if (args.kind !== "claim" && !livePriceUsd) {
      throw codedError("ORACLE_UNAVAILABLE: Umbrella actions require a current Convex token price.")
    }
    const liquid = await readLiquidBalance(ctx, wallet, args.marketId)
    const position = await readUmbrellaPosition(ctx, wallet, args.marketId)
    const accruedUsd = position ? rewardAccruedUsd(position, now) : 0
    const earnedUsd = position ? numberFromUsd6(position.earnedUsd6) + accruedUsd : 0
    const suppliedUsd = position ? numberFromUsd6(position.suppliedUsd6) : 0
    const cooldownUsd = position ? numberFromUsd6(position.cooldownAmountUsd6) : 0
    // `amountUsd` moves the token ledger; the receipt and activity rows carry the live USD value.
    const amountUsd = ledgerUsdFromTokens(args.marketId, amount)
    let nextPositionId: Id<"positions"> | undefined = position?._id
    let txAmountUsd = amount * (livePriceUsd ?? market.priceUsd)
    const amountsBefore: UmbrellaAmounts = position
      ? { suppliedUsd6: position.suppliedUsd6, cooldownAmountUsd6: position.cooldownAmountUsd6 }
      : null

    if (args.kind === "stake") {
      if (amount > liquid) throw codedError("INSUFFICIENT_BALANCE")
      await upsertLiquidBalance(ctx, wallet, args.marketId, liquid - amount, now, livePriceUsd!)
      const nextSuppliedUsd = suppliedUsd + amountUsd
      const payload = {
        wallet,
        product: "umbrella" as const,
        marketSlug: args.marketId,
        assetId: args.marketId,
        status: "open" as const,
        suppliedUsd6: usd6(nextSuppliedUsd),
        earnedUsd6: usd6(earnedUsd),
        supplyApyPct: market.apy,
        cooldownAmountUsd6: usd6(cooldownUsd),
        openedAt: position?.openedAt ?? now,
        lastUpdatedAt: now,
        // earnedUsd already folded accrual up to `now`, so restart the reward clock here.
        rewardCheckpointAt: now,
        openTxSynthetic: position?.openTxSynthetic,
        revision: (position?.revision ?? 0) + 1,
      }
      nextPositionId = position
        ? position._id
        : await ctx.db.insert("positions", { ...payload, openTxSynthetic: `sim-umb-${now.toString(36)}` })
      if (position) await ctx.db.patch(position._id, payload)
    } else if (args.kind === "claim") {
      if (!position || earnedUsd <= 0) throw new Error("NO_REWARDS")
      txAmountUsd = earnedUsd
      await ctx.db.patch(position._id, {
        earnedUsd6: "0",
        claimedRewardsUsd6: usd6(numberFromUsd6(position.claimedRewardsUsd6) + earnedUsd),
        lastUpdatedAt: now,
        // Claim zeroes earnedUsd6 — restart accrual from now.
        rewardCheckpointAt: now,
        revision: (position.revision ?? 0) + 1,
      })
    } else if (args.kind === "startCooldown") {
      if (!position) throw codedError("INVALID_COOLDOWN_AMOUNT")
      // A wallet may hold several concurrent tranches per market, each on its own 20-day /
      // 2-day clock, as long as total cooling <= supplied. The budget is
      // `supplied - (cooling + ready)`: EXPIRED tranches are excluded, because a lapsed
      // window never removed the principal from `suppliedUsd` — counting it as cooling
      // stranded the funds as neither withdrawable nor re-coolable.
      const activeTranches = await listActiveTranches(ctx, wallet, args.marketId)
      const expiredTranches = activeTranches.filter((t) => deriveTrancheStatus(t, now) === "expired")
      const nonExpiredTranches = activeTranches.filter((t) => deriveTrancheStatus(t, now) !== "expired")
      const activeCoolingUsd6 = nonExpiredTranches.reduce((sum, t) => sum + BigInt(t.amountUsd6), 0n)
      const activeCoolingUsd = Number(activeCoolingUsd6) / 1_000_000
      if (amountUsd > suppliedUsd - activeCoolingUsd + 1e-9) throw codedError("INVALID_COOLDOWN_AMOUNT")
      // Retire the recovered expired tranches so they leave the aggregate and can never be
      // double-counted against the new one. This is the UI's "restart cooldown" path.
      for (const tranche of expiredTranches) {
        await ctx.db.patch(tranche._id, { amountUsd6: "0", status: "consumed", updatedAt: now })
      }
      await ctx.db.insert("umbrellaCooldownTranches", {
        positionId: position._id,
        wallet,
        marketId: args.marketId,
        amountUsd6: usd6(amountUsd),
        startedAt: now,
        endsAt: now + COOLDOWN_MS,
        windowEndsAt: now + COOLDOWN_MS + WITHDRAWAL_WINDOW_MS,
        status: "cooling",
        createdAt: now,
        updatedAt: now,
      })
      await ctx.db.patch(position._id, {
        earnedUsd6: usd6(earnedUsd),
        // earnedUsd6 folds in accrual up to `now`, so the reward clock restarts.
        rewardCheckpointAt: now,
        revision: (position.revision ?? 0) + 1,
      })
      await recomputePositionAggregate(ctx, wallet, args.marketId, position._id, now)
    } else {
      if (!position) throw codedError("COOLDOWN_NOT_READY")
      // Unstake consumes ready tranches FIFO (earliest endsAt first). An expired tranche
      // still carrying cooling USD means the window lapsed and must be restarted — never
      // silently swallowed.
      const activeTranches = await listActiveTranches(ctx, wallet, args.marketId)
      const readyTranches = activeTranches
        .filter((t) => now >= t.endsAt && now < t.windowEndsAt)
        .sort((a, b) => a.endsAt - b.endsAt)
      const expiredTranches = activeTranches.filter((t) => now >= t.windowEndsAt)
      const readyUsd6 = readyTranches.reduce((sum, t) => sum + BigInt(t.amountUsd6), 0n)
      const readyUsd = Number(readyUsd6) / 1_000_000
      if (readyTranches.length === 0) {
        if (expiredTranches.length > 0) throw codedError("WITHDRAWAL_WINDOW_EXPIRED")
        throw codedError("COOLDOWN_NOT_READY")
      }
      if (amountUsd > readyUsd + 1e-9) throw codedError("INSUFFICIENT_COOLDOWN_BALANCE")
      // Consume FIFO across ready tranches.
      let remaining = amountUsd
      for (const tranche of readyTranches) {
        if (remaining <= 1e-9) break
        const trancheUsd = Number(BigInt(tranche.amountUsd6)) / 1_000_000
        const take = Math.min(trancheUsd, remaining)
        remaining -= take
        const nextUsd = trancheUsd - take
        if (nextUsd <= 1e-9) {
          await ctx.db.patch(tranche._id, {
            amountUsd6: "0",
            status: "consumed",
            updatedAt: now,
          })
        } else {
          await ctx.db.patch(tranche._id, {
            amountUsd6: usd6(nextUsd),
            updatedAt: now,
          })
        }
      }
      await upsertLiquidBalance(ctx, wallet, args.marketId, liquid + amount, now, livePriceUsd!)
      const nextSuppliedUsd = Math.max(0, suppliedUsd - amountUsd)
      await ctx.db.patch(position._id, {
        status: nextSuppliedUsd > 0 ? "open" : "closed",
        suppliedUsd6: usd6(nextSuppliedUsd),
        earnedUsd6: usd6(earnedUsd),
        // earnedUsd6 folds accrual up to `now`; reset the clock.
        rewardCheckpointAt: now,
        closedAt: nextSuppliedUsd > 0 ? undefined : now,
        revision: (position.revision ?? 0) + 1,
      })
      await recomputePositionAggregate(ctx, wallet, args.marketId, position._id, now)
    }
    const amountsAfter = nextPositionId ? await ctx.db.get(nextPositionId) : null
    await applyUmbrellaTotalsDelta(ctx, args.marketId, amountsBefore, amountsAfter, now)

    const syntheticTxHash = `sim-umbrella-${args.kind}-${args.marketId}-${now.toString(36)}`
    const receipt = await ctx.db.insert("transactions", {
      wallet,
      intentId: args.intentId,
      product: "umbrella",
      kind: args.kind,
      status: "success",
      marketSlug: args.marketId,
      assetId: args.marketId,
      positionId: nextPositionId,
      requestedAmountUsd6: usd6(txAmountUsd),
      executedAmountUsd6: usd6(txAmountUsd),
      amountUsd: txAmountUsd,
      syntheticTxHash,
      simulated: true,
      at: now,
    })
    await ctx.db.insert("sandboxActivity", {
      wallet,
      kind: `umbrella_${args.kind}`,
      amountUsd: txAmountUsd,
      marketSlug: args.marketId,
      syntheticTxHash,
      at: now,
    })
    return { idempotent: false, receipt: (await ctx.db.get(receipt))! }
  },
})

/**
 * Fixture seed for the open-gate test wallet (0x0000…0a11): staked positions, cooldown state,
 * pending rewards and matching wallet balances, so /umbrella demos without full onboarding.
 * Requires an authenticated sandbox wallet, accepts ONLY the canonical test wallet address,
 * and is idempotent (exits early if any umbrella position exists).
 */
const TEST_WALLET_ADDRESS = "0x0000000000000000000000000000000000000a11"

const UMBRELLA_TEST_FIXTURE = {
  balances: [
    { assetSlug: "gho" as UmbrellaMarketId, symbol: "GHO", amount: 20_000 },
    { assetSlug: "usdc" as UmbrellaMarketId, symbol: "USDC", amount: 25_000 },
    { assetSlug: "usdt" as UmbrellaMarketId, symbol: "USDT", amount: 15_000 },
    { assetSlug: "weth" as UmbrellaMarketId, symbol: "WETH", amount: 5 },
  ],
  positions: [
    {
      marketId: "gho" as const,
      suppliedUsd: 5_000,
      earnedUsd: 11.4,
      cooldownUsd: 2_500,
      cooldownOffsetMs: 11 * 24 * 60 * 60 * 1000,
    },
    { marketId: "usdc" as const, suppliedUsd: 8_000, earnedUsd: 18.25, cooldownUsd: 0, cooldownOffsetMs: null },
    { marketId: "usdt" as const, suppliedUsd: 0, earnedUsd: 0, cooldownUsd: 0, cooldownOffsetMs: null },
    // Ledger units (reference price): 3 WETH, the amount the original $6,720 at $2,240 staked.
    {
      marketId: "weth" as const,
      suppliedUsd: 3 * UMBRELLA_MARKETS.weth.priceUsd,
      earnedUsd: 9.1,
      cooldownUsd: 0,
      cooldownOffsetMs: null,
    },
  ],
} as const

/**
 * Shared umbrella-seed helper: liquid/aggregate balances, open positions, and one
 * `sandboxActivity` row per position in the shape `recordAction` produces. Both
 * `ensureTestWalletFixtures` and the onboarding claim go through it, so parity is by
 * construction. WRITES UNCONDITIONALLY — idempotency is the caller's job.
 */
export async function seedUmbrellaWallet(ctx: MutationCtx, wallet: string, now: number) {
  const receiptHashes: string[] = []

  for (const balance of UMBRELLA_TEST_FIXTURE.balances) {
    await upsertLiquidBalance(ctx, wallet, balance.assetSlug, balance.amount, now)
  }

  for (const position of UMBRELLA_TEST_FIXTURE.positions) {
    if (position.suppliedUsd <= 0) continue
    const cooldownStartedAt = position.cooldownOffsetMs == null ? undefined : now - position.cooldownOffsetMs
    const cooldownEndsAt = cooldownStartedAt == null ? undefined : cooldownStartedAt + COOLDOWN_MS
    const withdrawalWindowEndsAt = cooldownEndsAt == null ? undefined : cooldownEndsAt + WITHDRAWAL_WINDOW_MS
    const hash = `sim-umbrella-seed-${position.marketId}-${now.toString(36)}`
    receiptHashes.push(hash)
    const positionId = await ctx.db.insert("positions", {
      wallet,
      product: "umbrella",
      marketSlug: position.marketId,
      assetId: position.marketId,
      status: "open",
      suppliedUsd6: usd6(position.suppliedUsd),
      earnedUsd6: usd6(position.earnedUsd),
      supplyApyPct: UMBRELLA_MARKETS[position.marketId].apy,
      cooldownAmountUsd6: usd6(position.cooldownUsd),
      cooldownStartedAt,
      cooldownEndsAt,
      withdrawalWindowEndsAt,
      claimedRewardsUsd6: "0",
      openedAt: now,
      lastUpdatedAt: now,
      rewardCheckpointAt: now,
      openTxSynthetic: hash,
      revision: 1,
    })
    await applyUmbrellaTotalsDelta(
      ctx,
      position.marketId,
      null,
      { suppliedUsd6: usd6(position.suppliedUsd), cooldownAmountUsd6: usd6(position.cooldownUsd) },
      now,
    )
    // A fixture position with cooldownUsd > 0 seeds exactly ONE tranche, keeping the
    // per-tranche truth consistent with the aggregate; splitting is startCooldown's job.
    if (
      position.cooldownUsd > 0 &&
      cooldownStartedAt !== undefined &&
      cooldownEndsAt !== undefined &&
      withdrawalWindowEndsAt !== undefined
    ) {
      const seededStatus: "cooling" | "ready" | "expired" =
        now < cooldownEndsAt ? "cooling" : now < withdrawalWindowEndsAt ? "ready" : "expired"
      await ctx.db.insert("umbrellaCooldownTranches", {
        positionId,
        wallet,
        marketId: position.marketId,
        amountUsd6: usd6(position.cooldownUsd),
        startedAt: cooldownStartedAt,
        endsAt: cooldownEndsAt,
        windowEndsAt: withdrawalWindowEndsAt,
        status: seededStatus,
        createdAt: now,
        updatedAt: now,
      })
    }
    await ctx.db.insert("transactions", {
      wallet,
      intentId: `seed-umbrella-${position.marketId}`,
      product: "umbrella",
      kind: "stake",
      status: "success",
      marketSlug: position.marketId,
      assetId: position.marketId,
      positionId,
      requestedAmountUsd6: usd6(position.suppliedUsd),
      executedAmountUsd6: usd6(position.suppliedUsd),
      amountUsd: position.suppliedUsd,
      syntheticTxHash: hash,
      simulated: true,
      at: now,
    })
    // Parity with `recordAction`: every umbrella action writes a sandboxActivity row, so the
    // seed must too or the activity feed misses the initial stakes.
    await ctx.db.insert("sandboxActivity", {
      wallet,
      kind: "umbrella_stake",
      amountUsd: position.suppliedUsd,
      marketSlug: position.marketId,
      syntheticTxHash: hash,
      at: now,
    })
  }

  return { receiptHashes }
}

export const ensureTestWalletFixtures = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    if (wallet !== TEST_WALLET_ADDRESS) return { seeded: false, reason: "not-test-wallet" as const }

    const existing = await ctx.db
      .query("positions")
      .withIndex("by_wallet_product", (q) => q.eq("wallet", wallet).eq("product", "umbrella"))
      .collect()
    if (existing.length > 0) return { seeded: false, reason: "already-seeded" as const }

    const now = Date.now()
    await seedUmbrellaWallet(ctx, wallet, now)
    return { seeded: true }
  },
})

/** Dev-only: overwrite a market's live deficit so the stress view can demo a realized loss
 *  above the deficit offset. Gated by `SANDBOX_DEV_CONTROLS=true`. */
export const simulateDeficit = mutation({
  args: { wallet: v.string(), marketId: umbrellaMarketId, realizedUsd: v.number() },
  handler: async (ctx, args) => {
    assertSandboxDevControlsEnabled()
    await requireSandboxWallet(ctx, args.wallet)
    const overlay = await readUmbrellaMarketOverlay(ctx, args.marketId)
    const now = Date.now()
    const next = {
      marketId: args.marketId,
      currentDeficitUsd: Math.max(0, args.realizedUsd),
      deficitOffsetUsd: overlay.deficitOffsetUsd,
      totalSlashedUsd: overlay.totalSlashedUsd,
      updatedAt: now,
    }
    if (overlay.row) await ctx.db.patch(overlay.row._id, next)
    else await ctx.db.insert("umbrellaMarketState", next)
    return { marketId: args.marketId, currentDeficitUsd: next.currentDeficitUsd }
  },
})

/**
 * Dev-only: pro-rata slash across every open position for a market when the live deficit
 * exceeds the deficit offset. Active AND cooling stake are eligible — slashing applies until
 * the withdrawal window closes — while closed positions are exempt.
 */
export const simulateSlash = mutation({
  args: { wallet: v.string(), marketId: umbrellaMarketId },
  handler: async (ctx, args) => {
    assertSandboxDevControlsEnabled()
    await requireSandboxWallet(ctx, args.wallet)
    const overlay = await readUmbrellaMarketOverlay(ctx, args.marketId)
    const slashable = Math.max(0, overlay.currentDeficitUsd - overlay.deficitOffsetUsd)
    if (slashable <= 0) return { slashedUsd: 0, affected: 0 }
    const now = Date.now()

    const positions = await ctx.db
      .query("positions")
      .withIndex("by_product_market", (q) => q.eq("product", "umbrella").eq("marketSlug", args.marketId))
      .collect()
    const openPositions = positions.filter((row) => row.status === "open")
    let totalEligibleUsd = 0
    for (const row of openPositions) {
      totalEligibleUsd += numberFromUsd6(row.suppliedUsd6) + numberFromUsd6(row.cooldownAmountUsd6)
    }
    if (totalEligibleUsd <= 0) return { slashedUsd: 0, affected: 0 }

    const cap = Math.min(slashable, totalEligibleUsd)
    const ratio = cap / totalEligibleUsd
    let realized = 0
    for (const row of openPositions) {
      const suppliedUsd = numberFromUsd6(row.suppliedUsd6)
      const cooldownUsd = numberFromUsd6(row.cooldownAmountUsd6)
      const seizeStake = suppliedUsd * ratio
      const seizeCooldown = cooldownUsd * ratio
      const nextSupplied = Math.max(0, suppliedUsd - seizeStake)
      const totalSeized = seizeStake + seizeCooldown
      realized += totalSeized
      const priorSlashed = numberFromUsd6(row.slashedAmountUsd6)
      // Spread the cooling seizure pro-rata across the wallet's active tranches; a tranche
      // driven to zero becomes "consumed" and the aggregate is refolded below.
      const tranches = await listActiveTranches(ctx, row.wallet, args.marketId)
      for (const tranche of tranches) {
        const trancheUsd = Number(BigInt(tranche.amountUsd6)) / 1_000_000
        const seize = trancheUsd * ratio
        const nextUsd = Math.max(0, trancheUsd - seize)
        if (nextUsd <= 1e-9) {
          await ctx.db.patch(tranche._id, { amountUsd6: "0", status: "consumed", updatedAt: now })
        } else {
          await ctx.db.patch(tranche._id, { amountUsd6: usd6(nextUsd), updatedAt: now })
        }
      }
      await ctx.db.patch(row._id, {
        suppliedUsd6: usd6(nextSupplied),
        slashedAmountUsd6: usd6(priorSlashed + totalSeized),
        lastUpdatedAt: now,
        revision: (row.revision ?? 0) + 1,
      })
      await recomputePositionAggregate(ctx, row.wallet, args.marketId, row._id, now)
      await applyUmbrellaTotalsDelta(ctx, args.marketId, row, await ctx.db.get(row._id), now)
      await ctx.db.insert("sandboxActivity", {
        wallet: row.wallet,
        kind: "umbrella_slash",
        amountUsd: seizeStake + seizeCooldown,
        marketSlug: args.marketId,
        syntheticTxHash: `sim-umbrella-slash-${args.marketId}-${row._id}-${now.toString(36)}`,
        at: now,
      })
    }

    const nextOverlay = {
      marketId: args.marketId,
      currentDeficitUsd: Math.max(0, overlay.currentDeficitUsd - realized),
      deficitOffsetUsd: overlay.deficitOffsetUsd,
      totalSlashedUsd: overlay.totalSlashedUsd + realized,
      updatedAt: now,
    }
    if (overlay.row) await ctx.db.patch(overlay.row._id, nextOverlay)
    else await ctx.db.insert("umbrellaMarketState", nextOverlay)
    return { slashedUsd: realized, affected: openPositions.length }
  },
})
