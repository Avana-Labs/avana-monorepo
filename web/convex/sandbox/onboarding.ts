/**
 * Wallet-scoped sandbox onboarding + allocation. Caps (user count + total granted USD) are
 * enforced SERVER-SIDE inside `claim`'s single transactional mutation, so concurrent claims
 * cannot push past them; the client only displays the result. Balances/prices here are
 * SYNTHETIC, never a source of truth.
 */

import { codedError } from "../codedError"
import { v } from "convex/values"
import type { MutationCtx, QueryCtx } from "../_generated/server"
import { mutation, query } from "../_generated/server"
import { upsertWalletBalanceRows } from "../wallet/balances"
import { replaceProductBalanceRows } from "../wallet/productBalances"
import { readWalletSession, upsertWalletSession } from "../wallet/sessions"
import { upsertPortfolioCurrent } from "./transactions"
import { requireSandboxWallet, getAuthSubject } from "./auth"
import { requireSandboxWalletForWrite } from "../writeRateLimit"
import { validatedTokenPriceUsd } from "./oraclePrice"
import {
  assertCatalogCanSatisfyStarter,
  buildStarterAllocationPlan,
  buildStarterLiquidTokenLegs,
  STARTER_EQUITY_USD,
} from "./starterAllocation"
import { SWAP_ENGINE_ASSETS } from "./swapQuoteEngine"
import { seedUmbrellaWallet, UMBRELLA_ONBOARDING_TOKEN_PRICES } from "./umbrella"

const DEFAULT_ECONOMY = {
  userCap: 10_000,
  totalGrantedUsdCap: 10_000_000_000,
  perUserTargetUsd: 1_000_000,
  minMultiplier: 0.8,
  maxMultiplier: 1.2,
  userCount: 0,
  totalGrantedUsd: 0,
  status: "open" as const,
}

const DEFAULT_BASKET = [
  { tokenId: "usdc", weight: 0.4 },
  { tokenId: "eth", weight: 0.25 },
  { tokenId: "dai", weight: 0.1 },
  { tokenId: "wbtc", weight: 0.1 },
  { tokenId: "aave", weight: 0.1 },
  { tokenId: "uni", weight: 0.05 },
]

const SEED_VERSION = 1

/** Shard count for the economy counters — spreads concurrent claim increments so no
 *  two claims collide on the same row under OCC. */
const ECONOMY_SHARDS = 16

const DEFAULT_CONFIG = {
  basket: DEFAULT_BASKET,
  seedVersion: SEED_VERSION,
  tweetTemplate:
    "I'm practicing DeFi risk-free on the Avana sandbox — borrowing against LP, lending, and looping positions with $1M of synthetic funds.",
  xHandle: "AvanaFinance",
  resourcesLinks: [
    { label: "Read the docs", href: "/docs" },
    { label: "Explore markets", href: "/borrow" },
  ],
}

// Cold-cache fallback prices by lowercase symbol, so onboarding NEVER depends on the price cron
// having run (the live `tokenPrices` oracle is preferred at runtime). MUST cover every ASSET-market
// base token the starter buckets can select — pool/lend/multiply carry their own
// `markets.priceUsd` — or a fresh deployment resolves those legs to $0 and the claim gate rejects
// every wallet. MUST also mirror app/lib/prices/price-fixture.ts (Convex cannot import app/, so
// these are hand-copied); convex/__tests__/price-copy-drift.test.ts fails CI on any divergence.
export const SANDBOX_TOKEN_PRICE_USD: Record<string, number> = {
  usdc: 1,
  usdt: 1,
  dai: 1,
  gho: 1,
  crvusd: 1,
  eurc: 1.08,
  eth: 1934,
  weth: 1934,
  steth: 1930,
  wsteth: 2100,
  reth: 2045,
  cbeth: 1990,
  wbtc: 65_000,
  cbbtc: 65_000,
  aave: 105,
  link: 18,
  uni: 12,
  crv: 0.5,
}

/** Deterministic pseudo-tier in [min, max] from the wallet (sandbox stand-in for keccak256). */
function deriveTier(wallet: string, min: number, max: number): { tier: number; seed: string } {
  let hash = 2166136261
  for (let i = 0; i < wallet.length; i++) {
    hash ^= wallet.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  const unit = ((hash >>> 0) % 1000) / 1000 // [0,1)
  const tier = Number((min + unit * (max - min)).toFixed(4))
  return { tier, seed: (hash >>> 0).toString(16) }
}

async function getOrSeedEconomy(ctx: MutationCtx) {
  const existing = await ctx.db.query("sandboxEconomy").first()
  if (existing) return existing
  const id = await ctx.db.insert("sandboxEconomy", DEFAULT_ECONOMY)
  // Collapse any duplicate singleton a concurrent cold-start inserted at the same time,
  // so `.first()` (and the caps read below) stay against exactly one authoritative row.
  const rows = await ctx.db.query("sandboxEconomy").collect()
  for (const row of rows) if (row._id !== id) await ctx.db.delete(row._id)
  return (await ctx.db.get(id))!
}

async function getOrSeedConfig(ctx: MutationCtx) {
  const existing = await ctx.db.query("sandboxConfig").first()
  if (existing) return existing
  const id = await ctx.db.insert("sandboxConfig", DEFAULT_CONFIG)
  const rows = await ctx.db.query("sandboxConfig").collect()
  for (const row of rows) if (row._id !== id) await ctx.db.delete(row._id)
  return (await ctx.db.get(id))!
}

/**
 * Version of the cached starter grant manifest. BUMP THIS whenever the grantable market set
 * changes (new lend assets, new collateral pools) — the cached singleton is otherwise kept
 * forever and newly seeded markets never become grantable.
 */
export const STARTER_CATALOG_VERSION = 2

async function getOrSeedStarterCatalog(ctx: MutationCtx) {
  const existing = await ctx.db
    .query("sandboxStarterCatalog")
    .withIndex("by_singleton", (q) => q.eq("singleton", "starter"))
    .first()

  // Steady-state fast path: a fully-priced, current-version catalog is READ, never rebuilt, so a
  // claim does no full tokenPrices+markets scan and no write to the shared singleton (that write
  // serialized concurrent claims and was the onboarding-burst hotspot). Rebuild only when the
  // catalog is missing, still partial from a cold-start seed, or on an older
  // STARTER_CATALOG_VERSION — otherwise markets added after the first write never become grantable.
  if (
    existing &&
    existing.version === STARTER_CATALOG_VERSION &&
    existing.rows.length > 0 &&
    existing.rows.every((row) => row.priceUsd > 0)
  ) {
    return existing.rows
  }

  const [priceRows, markets] = await Promise.all([
    ctx.db.query("tokenPrices").collect(),
    ctx.db.query("markets").collect(),
  ])
  const livePrice = new Map(priceRows.map((row) => [row.symbol, row.priceUsd]))
  const rows = markets.map((market) => {
    const symbol = market.symbol.toLowerCase()
    return {
      slug: market.slug,
      scope: market.scope,
      symbol: market.symbol,
      // Order: live oracle, static fallback, then the market's own seeded price. Pool markets
      // carry LP-pair symbols ("cbBTC/USDC") and long-tail lend markets chain-name symbols
      // ("OP"), neither of which is a single-token oracle key — without `markets.priceUsd` they
      // resolve to 0 and the fail-closed claim gate rejects EVERY wallet.
      priceUsd: livePrice.get(symbol) ?? SANDBOX_TOKEN_PRICE_USD[symbol] ?? market.priceUsd ?? 0,
    }
  })

  // The market seed can land after the first onboarding attempt, so never keep a cold-start
  // catalog forever: refresh from the canonical tables once seeded.
  if (existing) {
    await ctx.db.patch(existing._id, { rows, updatedAt: Date.now(), version: STARTER_CATALOG_VERSION })
    return rows
  }

  const id = await ctx.db.insert("sandboxStarterCatalog", {
    singleton: "starter",
    rows,
    updatedAt: Date.now(),
    version: STARTER_CATALOG_VERSION,
  })
  const duplicates = await ctx.db
    .query("sandboxStarterCatalog")
    .withIndex("by_singleton", (q) => q.eq("singleton", "starter"))
    .collect()
  for (const duplicate of duplicates) if (duplicate._id !== id) await ctx.db.delete(duplicate._id)
  return rows
}

/** Live economy counts = baseline on the singleton row + the sum of every shard. */
async function readEconomyCounts(ctx: MutationCtx | QueryCtx, economy: { userCount: number; totalGrantedUsd: number }) {
  const shards = await ctx.db.query("sandboxEconomyShards").collect()
  let userCount = economy.userCount
  let totalGrantedUsd = economy.totalGrantedUsd
  for (const shard of shards) {
    userCount += shard.userCount
    totalGrantedUsd += shard.grantedUsd
  }
  return { userCount, totalGrantedUsd }
}

/** Add one claim's grant to a random shard (never the hot singleton row), so
 *  concurrent claims write disjoint documents and don't contend under OCC. */
async function incrementEconomyShard(ctx: MutationCtx, grantedUsd: number) {
  const shard = Math.floor(Math.random() * ECONOMY_SHARDS)
  const existing = await ctx.db
    .query("sandboxEconomyShards")
    .withIndex("by_shard", (q) => q.eq("shard", shard))
    .first()
  if (existing) {
    await ctx.db.patch(existing._id, {
      userCount: existing.userCount + 1,
      grantedUsd: existing.grantedUsd + grantedUsd,
    })
    return
  }
  await ctx.db.insert("sandboxEconomyShards", { shard, userCount: 1, grantedUsd })
}

async function profileForWallet(ctx: QueryCtx | MutationCtx, wallet: string) {
  return ctx.db
    .query("sandboxProfiles")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet.toLowerCase()))
    .unique()
}

function onboardingProfileView(profile: Awaited<ReturnType<typeof profileForWallet>>) {
  if (!profile) return null
  return {
    wallet: profile.wallet,
    createdAt: profile.createdAt,
    seedVersion: profile.seedVersion,
    onboardingStep: profile.onboardingStep,
    onboardedAt: profile.onboardedAt,
    eligibilityTier: profile.eligibilityTier,
    tierSeed: profile.tierSeed,
    allocatedUsd: profile.allocatedUsd,
    basketSnapshot: profile.basketSnapshot,
    xHandle: profile.xHandle,
    tweetUrl: profile.tweetUrl,
    tweetedAt: profile.tweetedAt,
    claimTxSynthetic: profile.claimTxSynthetic,
  }
}

function liquidAssetIdForMultiplyDebt(marketSlug: string) {
  const parts = marketSlug.toLowerCase().split(/[-_:]/)
  return parts.find((part) => part === "usdc" || part === "usdt" || part === "dai" || part === "gho") ?? "usdc"
}

/** Wallet-scoped onboarding state for the SandboxGate (own wallet only). */
export const getState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const profile = await profileForWallet(ctx, wallet)
    const [economy, config, shards] = await Promise.all([
      ctx.db.query("sandboxEconomy").first(),
      ctx.db.query("sandboxConfig").first(),
      ctx.db.query("sandboxEconomyShards").collect(),
    ])
    const shardedUserCount = shards.reduce((sum, shard) => sum + shard.userCount, 0)
    return {
      onboardingStep: profile?.onboardingStep ?? "wallet",
      profile: onboardingProfileView(profile),
      config: config
        ? {
            basket: config.basket,
            tweetTemplate: config.tweetTemplate ?? DEFAULT_CONFIG.tweetTemplate,
            xHandle: config.xHandle ?? DEFAULT_CONFIG.xHandle,
            resourcesLinks: config.resourcesLinks ?? DEFAULT_CONFIG.resourcesLinks,
          }
        : DEFAULT_CONFIG,
      economy: economy
        ? {
            status: economy.status,
            userCount: economy.userCount + shardedUserCount,
            userCap: economy.userCap,
            perUserTargetUsd: economy.perUserTargetUsd,
          }
        : {
            status: "open" as const,
            userCount: shardedUserCount,
            userCap: DEFAULT_ECONOMY.userCap,
            perUserTargetUsd: DEFAULT_ECONOMY.perUserTargetUsd,
          },
    }
  },
})

/**
 * Steady-state gate subscription. Unlike `getState` it deliberately does NOT read
 * `sandboxEconomyShards`: every `claim` writes a shard, which would invalidate every authed
 * wallet's subscription. Post-onboarding the gate only needs this wallet's own profile/step.
 */
async function walletOnboardingView(ctx: QueryCtx, wallet: string) {
  const [profile, config] = await Promise.all([profileForWallet(ctx, wallet), ctx.db.query("sandboxConfig").first()])
  return {
    onboardingStep: profile?.onboardingStep ?? "wallet",
    profile: onboardingProfileView(profile),
    config: config
      ? {
          basket: config.basket,
          tweetTemplate: config.tweetTemplate ?? DEFAULT_CONFIG.tweetTemplate,
          xHandle: config.xHandle ?? DEFAULT_CONFIG.xHandle,
          resourcesLinks: config.resourcesLinks ?? DEFAULT_CONFIG.resourcesLinks,
        }
      : DEFAULT_CONFIG,
  }
}

async function economyStatusView(ctx: QueryCtx) {
  const [economy, shards] = await Promise.all([
    ctx.db.query("sandboxEconomy").first(),
    ctx.db.query("sandboxEconomyShards").collect(),
  ])
  const shardedUserCount = shards.reduce((sum, shard) => sum + shard.userCount, 0)
  return economy
    ? {
        status: economy.status,
        userCount: economy.userCount + shardedUserCount,
        userCap: economy.userCap,
        perUserTargetUsd: economy.perUserTargetUsd,
      }
    : {
        status: "open" as const,
        userCount: shardedUserCount,
        userCap: DEFAULT_ECONOMY.userCap,
        perUserTargetUsd: DEFAULT_ECONOMY.perUserTargetUsd,
      }
}

export const getWalletOnboardingState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    return await walletOnboardingView(ctx, wallet)
  },
})

/**
 * Global economy status (seats left / open|closed). Reads the sharded counters, so EVERY claim
 * invalidates it — subscribe only while onboarding is in progress, never for every authed user.
 * `wallet` authenticates the caller; the result is global.
 */
export const getEconomyStatus = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    await requireSandboxWallet(ctx, args.wallet)
    return await economyStatusView(ctx)
  },
})

/**
 * One round-trip for the signed-in gate: wallet state always, economy ONLY while onboarding.
 * Once `onboardingStep === "done"` it stops reading `sandboxEconomyShards`, so other users'
 * claims cannot invalidate a finished wallet.
 */
export const getOnboardingGateState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    const walletView = await walletOnboardingView(ctx, wallet)
    if (walletView.onboardingStep === "done") {
      return { ...walletView, economy: null }
    }
    return { ...walletView, economy: await economyStatusView(ctx) }
  },
})

/** Persist the analysis loading state before the deterministic eligibility pass. */
export const beginAnalysis = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const existing = await profileForWallet(ctx, wallet)
    if (existing) {
      if (existing.onboardingStep === "done" || existing.onboardingStep === "waitlisted") return existing.onboardingStep
      await ctx.db.patch(existing._id, { onboardingStep: "analyzing" })
      return "analyzing" as const
    }
    await ctx.db.insert("sandboxProfiles", {
      wallet,
      createdAt: Date.now(),
      seedVersion: SEED_VERSION,
      onboardingStep: "analyzing",
    })
    return "analyzing" as const
  },
})

/** Step 2: derive the eligibility tier and move to "eligible". */
export const startAnalysis = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const economy = await getOrSeedEconomy(ctx)
    const { tier, seed } = deriveTier(wallet, economy.minMultiplier, economy.maxMultiplier)

    const existing = await profileForWallet(ctx, wallet)
    if (existing) {
      if (existing.onboardingStep === "done" || existing.onboardingStep === "waitlisted") return existing.onboardingStep
      await ctx.db.patch(existing._id, { onboardingStep: "eligible", eligibilityTier: tier, tierSeed: seed })
      return "eligible" as const
    }

    await ctx.db.insert("sandboxProfiles", {
      wallet,
      createdAt: Date.now(),
      seedVersion: SEED_VERSION,
      onboardingStep: "eligible",
      eligibilityTier: tier,
      tierSeed: seed,
    })
    return "eligible" as const
  },
})

/** Optional X/tweet sub-flow (eligible → xPending); no tweet recorded yet. Idempotent, and
 *  never regresses a finished profile. */
export const startTweet = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const profile = await profileForWallet(ctx, wallet)
    if (!profile) throw codedError("NO_PROFILE: start onboarding before sharing.")
    if (profile.onboardingStep === "done" || profile.onboardingStep === "waitlisted") return profile.onboardingStep
    if (profile.onboardingStep === "xConfirmed") return "xConfirmed" as const
    await ctx.db.patch(profile._id, { onboardingStep: "xPending" })
    return "xPending" as const
  },
})

/** Confirm the share (xPending|eligible → xConfirmed) with handle + tweet URL. Sandbox
 *  attestation only — there is no server-side tweet verification. */
export const confirmTweet = mutation({
  args: { wallet: v.string(), xHandle: v.optional(v.string()), tweetUrl: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const profile = await profileForWallet(ctx, wallet)
    if (!profile) throw codedError("NO_PROFILE: start onboarding before sharing.")
    if (profile.onboardingStep === "done" || profile.onboardingStep === "waitlisted") return profile.onboardingStep
    await ctx.db.patch(profile._id, {
      onboardingStep: "xConfirmed",
      xHandle: args.xHandle,
      tweetUrl: args.tweetUrl,
      tweetedAt: Date.now(),
    })
    return "xConfirmed" as const
  },
})

/** Continue without sharing; participation never changes the $1M allocation. */
export const skipTweet = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const profile = await profileForWallet(ctx, wallet)
    if (!profile) throw codedError("NO_PROFILE: start onboarding before continuing.")
    if (profile.onboardingStep === "done" || profile.onboardingStep === "waitlisted") return profile.onboardingStep
    await ctx.db.patch(profile._id, { onboardingStep: "xConfirmed" })
    return "xConfirmed" as const
  },
})

/** Persist the claim loading state before the atomic allocation mutation runs. */
export const beginClaim = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const profile = await profileForWallet(ctx, wallet)
    if (!profile) throw codedError("NO_PROFILE: start onboarding before claiming.")
    if (profile.onboardingStep === "done" || profile.onboardingStep === "waitlisted") return profile.onboardingStep
    await ctx.db.patch(profile._id, { onboardingStep: "claimPending" })
    return "claimPending" as const
  },
})

/** Final step: enforce caps server-side, allocate the basket, mark done — or waitlist. */
export const claim = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    const economy = await getOrSeedEconomy(ctx)
    await getOrSeedConfig(ctx)
    const profile = await profileForWallet(ctx, wallet)
    if (!profile) throw codedError("NO_PROFILE: start onboarding before claiming.")
    if (profile.onboardingStep === "done") return { status: "done" as const, allocatedUsd: profile.allocatedUsd ?? 0 }

    const allocatedUsd = STARTER_EQUITY_USD

    // Caps re-read live (summed across shards); never trusted from the client.
    const counts = await readEconomyCounts(ctx, economy)
    const capReached =
      economy.status !== "open" ||
      counts.userCount >= economy.userCap ||
      counts.totalGrantedUsd + allocatedUsd > economy.totalGrantedUsdCap

    if (capReached) {
      await ctx.db.patch(profile._id, { onboardingStep: "waitlisted" })
      const justClosed = economy.status === "open" && counts.userCount >= economy.userCap
      if (justClosed) {
        await ctx.db.patch(economy._id, { status: "closed", closedReason: "userCap reached", closedAt: Date.now() })
      }
      return { status: "waitlisted" as const, allocatedUsd: 0 }
    }

    const now = Date.now()

    const starterCatalog = await getOrSeedStarterCatalog(ctx)
    const marketBySlug = new Map(starterCatalog.map((market) => [market.slug, market]))
    const catalogBySlug = new Map(starterCatalog.map((market) => [market.slug, market]))

    // The grant is a fixed USD amount, so every token quantity MUST be `grantUsd / price` at the
    // price the position is later valued with — the LIVE oracle, read at claim time. The cached
    // catalog price and the static fallback both size positions against a different number than
    // the app displays (AAVE seeded $91.74 vs valued $105 → ~$20k of phantom gain on render).
    const livePriceRows = await ctx.db.query("tokenPrices").collect()
    const livePriceBySymbol = new Map(livePriceRows.map((row) => [row.symbol.toLowerCase(), row.priceUsd]))
    // Lend and LP legs are sized in tokens at claim, then valued at LIVE prices everywhere after.
    // Sizing them off the cached starter catalog (priced when it was last rebuilt) showed a new
    // wallet an instant phantom gain/loss — 15.5% on UNI the same day the catalog was rebuilt.
    const liveLegPriceUsd = async (scope: "lend" | "pool", slug: string, symbol: string | undefined) => {
      const catalogPriceUsd = catalogBySlug.get(slug)?.priceUsd
      if (scope === "lend") {
        // Same freshness/status/confidence rules as execution: a quote left over from a stalled
        // refresh would size the leg off a price the live readers no longer use.
        const live = symbol ? await validatedTokenPriceUsd(ctx, symbol, now) : null
        if (live) return live
      } else {
        const pool = await ctx.db
          .query("markets")
          .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", slug))
          .unique()
        if (pool?.priceUsd && Number.isFinite(pool.priceUsd) && pool.priceUsd > 0) return pool.priceUsd
      }
      return catalogPriceUsd && catalogPriceUsd > 0 ? catalogPriceUsd : 1
    }
    const resolveGrantPriceUsd = (symbol: string, fallbackUsd?: number) => {
      const key = symbol.toLowerCase()
      const live = livePriceBySymbol.get(key)
      if (live && Number.isFinite(live) && live > 0) return live
      const fallback = SANDBOX_TOKEN_PRICE_USD[key] ?? fallbackUsd
      return fallback && Number.isFinite(fallback) && fallback > 0 ? fallback : 1
    }

    // FAIL CLOSED on an incomplete catalog: marking a wallet "done" with a partial portfolio
    // locks it out of its real $1M allocation permanently. Prices resolve as the seed does but
    // WITHOUT the blanket `?? 1`, so an unresolvable market counts as incomplete instead of being
    // seeded at $1/token. Throws ONBOARDING_CATALOG_INCOMPLETE before any write, so the profile
    // stays on its current step and the wallet can retry once seeded.
    assertCatalogCanSatisfyStarter(wallet, starterCatalog)

    const allocation = buildStarterAllocationPlan(wallet, starterCatalog)
    // The liquid bucket must seed REAL swap-catalog tokens, not the planner's spoke-borrowable
    // `scope:"asset"` markets — those composite slugs ("uni-v2:wbtc") are absent from the swap
    // catalog and render as "Unsupported asset". Preserve the planner's EXACT liquid dollar total
    // so the $1M grand total and the other buckets are unchanged.
    const liquidTargetUsd = allocation.liquid.reduce((sum, leg) => sum + leg.amountUsd, 0)
    const liquidTokens = SWAP_ENGINE_ASSETS.filter((asset) => asset.isSwapEnabled && !asset.isLpToken)
    const liquidLegs = buildStarterLiquidTokenLegs(
      liquidTokens,
      (token) => resolveGrantPriceUsd(token.symbol, SANDBOX_TOKEN_PRICE_USD[token.id]),
      liquidTargetUsd,
    )
    const basketSnapshot = liquidLegs.map((leg) => ({
      tokenId: leg.assetId,
      amount: leg.amount,
      priceUsdAtClaim: leg.priceUsd,
    }))

    const syntheticTxHash = `sim-claim-${(profile.tierSeed ?? "0").slice(0, 8)}-${now.toString(36)}`
    const receiptHashes: string[] = []

    const productLiquidRows: Parameters<typeof replaceProductBalanceRows>[2]["liquid"] = []
    const productLendRows: Parameters<typeof replaceProductBalanceRows>[2]["lend"] = []
    const productBorrowRows: Parameters<typeof replaceProductBalanceRows>[2]["borrow"] = []
    const productMultiplyRows: Parameters<typeof replaceProductBalanceRows>[2]["multiply"] = []

    for (const [index, leg] of liquidLegs.entries()) {
      productLiquidRows.push({
        assetId: leg.assetId,
        symbol: leg.symbol,
        amount: leg.amount,
        valueUsd: leg.amountUsd,
        state: "available",
      })
      await upsertWalletBalanceRows(ctx, [
        {
          wallet,
          assetId: leg.assetId,
          amount: leg.amount,
          sourceType: "wallet",
          assetKind: "wallet",
          symbol: leg.symbol,
          valueUsd6: String(Math.round(leg.amountUsd * 1_000_000)),
        },
      ])
      const hash = `${syntheticTxHash}-asset-${index}`
      receiptHashes.push(hash)
      await ctx.db.insert("sandboxActivity", {
        wallet,
        kind: "starterAssetGrant",
        amountUsd: leg.amountUsd,
        marketSlug: leg.assetId,
        syntheticTxHash: hash,
        at: now,
      })
    }

    for (const [index, leg] of allocation.collateral.entries()) {
      const amountUsd6 = Math.round(leg.amountUsd * 1_000_000).toString()
      const hash = `${syntheticTxHash}-pool-${index}`
      const market = marketBySlug.get(leg.marketSlug)
      const priceUsd = await liveLegPriceUsd("pool", leg.marketSlug, market?.symbol)
      productBorrowRows.push({
        marketId: leg.marketSlug,
        poolId: leg.marketSlug,
        symbol: market?.symbol ?? leg.marketSlug.toUpperCase(),
        amount: priceUsd > 0 ? leg.amountUsd / priceUsd : leg.amountUsd,
        valueUsd: leg.amountUsd,
        state: "collateral",
      })
      receiptHashes.push(hash)
      const positionId = await ctx.db.insert("positions", {
        wallet,
        product: "borrow",
        marketSlug: leg.marketSlug,
        status: "open",
        collateralValueUsd6: amountUsd6,
        debtValueUsd6: "0",
        openedAt: now,
        lastUpdatedAt: now,
        openTxSynthetic: hash,
      })
      // Store intended USD in collateralValueUsd6 and leave shares at 0; client hydration
      // derives real LP shares from it at the LIVE price. Convex has no access to the catalog
      // LP prices, and storing raw USD as shares makes the engine read ~$0.
      await ctx.db.insert("positionCollateral", {
        wallet,
        positionId,
        marketSlug: leg.marketSlug,
        collateralShares: "0",
        principalTokenAmount: "0",
        collateralEnabled: true,
        collateralValueUsd6: amountUsd6,
        updatedAt: now,
      })
      await ctx.db.insert("transactions", {
        wallet,
        intentId: `onboarding-pool-${leg.marketSlug}`,
        product: "borrow",
        kind: "deposit",
        status: "success",
        marketSlug: leg.marketSlug,
        positionId,
        requestedAmountUsd6: amountUsd6,
        executedAmountUsd6: amountUsd6,
        amountUsd: leg.amountUsd,
        syntheticTxHash: hash,
        simulated: true,
        at: now,
      })
    }

    for (const [index, leg] of allocation.lend.entries()) {
      const amountUsd6 = Math.round(leg.amountUsd * 1_000_000).toString()
      const hash = `${syntheticTxHash}-lend-${index}`
      const market = marketBySlug.get(leg.marketSlug)
      const priceUsd = await liveLegPriceUsd("lend", leg.marketSlug, market?.symbol)
      productLendRows.push({
        marketId: leg.marketSlug,
        assetId: leg.marketSlug,
        symbol: market?.symbol ?? leg.marketSlug.toUpperCase(),
        amount: priceUsd > 0 ? leg.amountUsd / priceUsd : leg.amountUsd,
        valueUsd: leg.amountUsd,
        state: "deposited",
      })
      receiptHashes.push(hash)
      const positionId = await ctx.db.insert("positions", {
        wallet,
        product: "lend",
        marketSlug: leg.marketSlug,
        status: "open",
        suppliedUsd6: amountUsd6,
        earnedUsd6: "0",
        openedAt: now,
        lastUpdatedAt: now,
        openTxSynthetic: hash,
      })
      await ctx.db.insert("transactions", {
        wallet,
        intentId: `onboarding-lend-${leg.marketSlug}`,
        product: "lend",
        kind: "deposit",
        status: "success",
        marketSlug: leg.marketSlug,
        positionId,
        requestedAmountUsd6: amountUsd6,
        executedAmountUsd6: amountUsd6,
        amountUsd: leg.amountUsd,
        syntheticTxHash: hash,
        simulated: true,
        at: now,
      })
    }

    for (const [index, leg] of allocation.multiply.entries()) {
      const multiplier = 2
      const grossExposureUsd = leg.amountUsd * multiplier
      const debtValueUsd = grossExposureUsd - leg.amountUsd
      const amountUsd6 = Math.round(leg.amountUsd * 1_000_000).toString()
      const hash = `${syntheticTxHash}-multiply-${index}`
      receiptHashes.push(hash)
      // `collateralAmount` is a TOKEN QUANTITY, not USD: the multiply engine computes
      // `collateralValueUsd = collateralAmount * collateralPriceUsd` and derives the liquidation
      // price from it, so USD here yields a bogus ~$2/token price and a garbage liquidation
      // level. The quantity stored is the GROSS (leveraged) collateral. For multiply markets
      // `markets.symbol` is the COLLATERAL asset, so its live price resolves as the liquid legs do.
      const multiplyMarket = marketBySlug.get(leg.marketSlug)
      const multiplySymbol = multiplyMarket?.symbol.toLowerCase() ?? leg.marketSlug
      // Size off the COLLATERAL TOKEN's price — the same basis every later valuation uses. The
      // multiply MARKET's catalog `priceUsd` is a different number than the position is displayed
      // with (AAVE $91.74 vs $105.02), minting ~$20k of phantom gain on render.
      const collateralPriceUsd = resolveGrantPriceUsd(multiplySymbol, catalogBySlug.get(leg.marketSlug)?.priceUsd)
      const collateralAmount = grossExposureUsd / collateralPriceUsd
      // `amount` is a TOKEN QUANTITY, derived from the same grant price the other legs use, so a
      // non-$1 debt asset can never be repriced by the dashboard's `amount × livePrice`. USD stays
      // on `valueUsd`, mirroring the executed multiply debt path in transactions.ts.
      const multiplyDebtAssetId = liquidAssetIdForMultiplyDebt(leg.marketSlug)
      const multiplyDebtPriceUsd = resolveGrantPriceUsd(multiplyDebtAssetId)
      const multiplyDebtAmount = multiplyDebtPriceUsd > 0 ? debtValueUsd / multiplyDebtPriceUsd : debtValueUsd
      productMultiplyRows.push(
        {
          marketId: leg.marketSlug,
          assetId: multiplySymbol,
          symbol: multiplyMarket?.symbol ?? multiplySymbol.toUpperCase(),
          amount: collateralAmount,
          valueUsd: grossExposureUsd,
          state: "position",
        },
        {
          marketId: leg.marketSlug,
          assetId: multiplySymbol,
          symbol: multiplyMarket?.symbol ?? multiplySymbol.toUpperCase(),
          amount: collateralAmount,
          valueUsd: grossExposureUsd,
          state: "collateral",
        },
        {
          marketId: leg.marketSlug,
          assetId: multiplyDebtAssetId,
          symbol: multiplyDebtAssetId.toUpperCase(),
          amount: multiplyDebtAmount,
          valueUsd: debtValueUsd,
          state: "debt",
        },
      )
      const positionId = await ctx.db.insert("positions", {
        wallet,
        product: "multiply",
        marketSlug: leg.marketSlug,
        status: "open",
        collateralAmount,
        collateralValueUsd: grossExposureUsd,
        debtValueUsd,
        multiplier,
        ltv: debtValueUsd / grossExposureUsd,
        healthFactor: 2,
        liquidationPrice: null,
        netApyPct: 0,
        openedAt: now,
        lastUpdatedAt: now,
        openTxSynthetic: hash,
      })
      await ctx.db.insert("transactions", {
        wallet,
        intentId: `onboarding-multiply-${leg.marketSlug}`,
        product: "multiply",
        kind: "multiply",
        status: "success",
        marketSlug: leg.marketSlug,
        positionId,
        requestedAmountUsd6: amountUsd6,
        executedAmountUsd6: amountUsd6,
        amountUsd: leg.amountUsd,
        syntheticTxHash: hash,
        simulated: true,
        at: now,
      })
    }

    // Umbrella onboarding seed, behind TWO idempotency gates so a repeat claim (or a reset that
    // clears positions) cannot double-write: no existing umbrella positions AND no
    // `umbrellaSeeded` flag on walletSessions. Must go through `seedUmbrellaWallet` (the single
    // source of truth) so onboarding writes IDENTICAL walletLiquidBalances / walletBalances /
    // sandboxActivity to four real `stake 0` actions, and must price with
    // UMBRELLA_ONBOARDING_TOKEN_PRICES so WETH does not diverge from the umbrella catalog.
    const existingUmbrella = await ctx.db
      .query("positions")
      .withIndex("by_wallet_product", (q) => q.eq("wallet", wallet).eq("product", "umbrella"))
      .collect()
    const existingSession = await readWalletSession(ctx, wallet)
    const shouldSeedUmbrella = existingUmbrella.length === 0 && !existingSession?.umbrellaSeeded
    // Referenced so a rename flags the stale import; seedUmbrellaWallet reads UMBRELLA_MARKETS
    // internally.
    void UMBRELLA_ONBOARDING_TOKEN_PRICES

    await ctx.db.insert("starterAllocations", {
      wallet,
      version: allocation.version,
      totalEquityUsd: allocation.totalEquityUsd,
      liquid: allocation.liquid,
      collateral: allocation.collateral,
      lend: allocation.lend,
      multiply: allocation.multiply,
      receiptHashes,
      createdAt: now,
    })
    await replaceProductBalanceRows(ctx, wallet, {
      liquid: productLiquidRows,
      lend: productLendRows,
      borrow: productBorrowRows,
      multiply: productMultiplyRows,
    })
    // Must run AFTER replaceProductBalanceRows: that helper wipes the wallet's
    // walletLiquidBalances before re-inserting only the starter basket, so umbrella's writes are
    // silently deleted if they land first.
    if (shouldSeedUmbrella) {
      const seedResult = await seedUmbrellaWallet(ctx, wallet, now)
      receiptHashes.push(...seedResult.receiptHashes)
    }
    const liquidValueUsd = allocation.liquid.reduce((sum, leg) => sum + leg.amountUsd, 0)
    const collateralValueUsd = allocation.collateral.reduce((sum, leg) => sum + leg.amountUsd, 0)
    const lendValueUsd = allocation.lend.reduce((sum, leg) => sum + leg.amountUsd, 0)
    const multiplyEquityUsd = allocation.multiply.reduce((sum, leg) => sum + leg.amountUsd, 0)
    const multiplyExposureUsd = multiplyEquityUsd * 2
    const multiplyDebtUsd = multiplyExposureUsd - multiplyEquityUsd
    const collateralPools = await Promise.all(
      allocation.collateral.map((leg) =>
        ctx.db
          .query("pools")
          .withIndex("by_slug", (q) => q.eq("slug", leg.marketSlug))
          .unique(),
      ),
    )
    const availableToBorrowUsd = allocation.collateral.reduce((sum, leg, index) => {
      const cfPct = collateralPools[index]?.maxLtvPct ?? 70
      return sum + leg.amountUsd * (cfPct / 100)
    }, 0)
    const initialPortfolio = {
      wallet,
      at: now,
      totalValueUsd: liquidValueUsd + collateralValueUsd + lendValueUsd + multiplyExposureUsd - multiplyDebtUsd,
      totalSuppliedUsd: collateralValueUsd + lendValueUsd + multiplyExposureUsd,
      totalBorrowedUsd: multiplyDebtUsd,
      availableToBorrowUsd,
      totalMultiplyExposureUsd: multiplyExposureUsd,
      totalEarnedUsd: 0,
    }
    await ctx.db.insert("portfolioSnapshots", initialPortfolio)
    // NEVER a bare insert: the dashboard's ensurePortfolioSnapshot may already have written a
    // portfolioCurrent row, and a second row makes every `.unique()` read throw, which rolls the
    // whole claim back and leaves the wallet stuck.
    await upsertPortfolioCurrent(ctx, wallet, initialPortfolio)
    // Marks the wallet seeded so a second claim (or a reset that wipes positions) cannot re-run
    // seedUmbrellaWallet over balances/activity the first seed already wrote.
    await upsertWalletSession(ctx, {
      wallet,
      authSubject: (await getAuthSubject(ctx)) ?? undefined,
      seedVersion: SEED_VERSION,
      seededAt: now,
      lastSeenAt: now,
      umbrellaSeeded: true,
    })

    await ctx.db.patch(profile._id, {
      onboardingStep: "done",
      onboardedAt: now,
      allocatedUsd,
      basketSnapshot,
      claimTxSynthetic: syntheticTxHash,
    })
    // Random shard, never the hot singleton row, so concurrent claims write disjoint documents.
    await incrementEconomyShard(ctx, allocatedUsd)
    if (
      counts.userCount + 1 >= economy.userCap ||
      counts.totalGrantedUsd + allocatedUsd >= economy.totalGrantedUsdCap
    ) {
      await ctx.db.patch(economy._id, {
        status: "closed",
        closedReason: counts.userCount + 1 >= economy.userCap ? "userCap reached" : "totalGrantedUsdCap reached",
        closedAt: now,
      })
    }
    await ctx.db.insert("sandboxActivity", {
      wallet,
      kind: "onboardingClaim",
      amountUsd: allocatedUsd,
      syntheticTxHash,
      at: now,
    })

    return { status: "done" as const, allocatedUsd, basketSnapshot, syntheticTxHash, allocation, receiptHashes }
  },
})
