import { codedError } from "../codedError"
export const STARTER_EQUITY_USD = 1_000_000

export const STARTER_BUCKETS = {
  liquid: { amountUsd: 100_000, count: 12 },
  collateral: { amountUsd: 350_000, count: 8 },
  lend: { amountUsd: 300_000, count: 8 },
  multiply: { amountUsd: 250_000, count: 6 },
} as const

export type StarterMarket = {
  slug: string
  scope: "asset" | "pool" | "lend" | "multiply"
}

export type StarterAllocationLeg = {
  marketSlug: string
  amountUsd: number
}

export type StarterAllocationPlan = {
  version: 1
  wallet: string
  totalEquityUsd: number
  liquid: StarterAllocationLeg[]
  collateral: StarterAllocationLeg[]
  lend: StarterAllocationLeg[]
  multiply: StarterAllocationLeg[]
}

function hashWallet(wallet: string) {
  let hash = 2166136261
  for (let index = 0; index < wallet.length; index += 1) {
    hash ^= wallet.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return hash >>> 0
}

function greatestCommonDivisor(left: number, right: number): number {
  return right === 0 ? left : greatestCommonDivisor(right, left % right)
}

function selectionStride(length: number, seed: number) {
  if (length <= 1) return 1
  let stride = (seed % (length - 1)) + 1
  while (greatestCommonDivisor(stride, length) !== 1) {
    stride = (stride % (length - 1)) + 1
  }
  return stride
}

function splitExact(amountUsd: number, count: number) {
  const totalCents = Math.round(amountUsd * 100)
  const baseCents = Math.floor(totalCents / count)
  const remainder = totalCents - baseCents * count
  return Array.from({ length: count }, (_, index) => (baseCents + (index < remainder ? 1 : 0)) / 100)
}

export type StarterLiquidTokenLeg = {
  assetId: string
  symbol: string
  priceUsd: number
  amountUsd: number
  amount: number
}

/**
 * Build the liquid (wallet) starter legs from REAL swap-catalog tokens, not the planner's
 * spoke-borrowable `scope:"asset"` markets — their composite ids ("uni-v2:wbtc") are absent
 * from the swap catalog, so `getSwapAsset` cannot resolve them and the wallet renders
 * "Unsupported asset". `totalUsd` is split across `tokens` exactly, preserving the seeded
 * liquid total to the cent. A non-positive/NaN price degrades to 1 rather than Infinity.
 */
export function buildStarterLiquidTokenLegs(
  tokens: readonly { id: string; symbol: string }[],
  priceUsdFor: (token: { id: string; symbol: string }) => number,
  totalUsd: number,
): StarterLiquidTokenLeg[] {
  if (tokens.length === 0) return []
  const amounts = splitExact(totalUsd, tokens.length)
  return tokens.map((token, index) => {
    const resolved = priceUsdFor(token)
    const priceUsd = resolved > 0 && Number.isFinite(resolved) ? resolved : 1
    const amountUsd = amounts[index]!
    return { assetId: token.id, symbol: token.symbol, priceUsd, amountUsd, amount: amountUsd / priceUsd }
  })
}

function allocateBucket(
  candidates: StarterMarket[],
  amountUsd: number,
  desiredCount: number,
  seed: number,
): StarterAllocationLeg[] {
  if (candidates.length === 0) {
    throw codedError("STARTER_CATALOG_INCOMPLETE: allocation bucket has no eligible markets.")
  }
  const normalizedSeed = seed >>> 0
  const count = Math.min(desiredCount, candidates.length)
  const start = normalizedSeed % candidates.length
  const stride = selectionStride(candidates.length, normalizedSeed >>> 8)
  const selected: StarterMarket[] = []
  const seen = new Set<number>()

  for (let cursor = 0; selected.length < count; cursor += 1) {
    const index = (start + cursor * stride) % candidates.length
    if (seen.has(index)) continue
    seen.add(index)
    selected.push(candidates[index]!)
  }

  const amounts = splitExact(amountUsd, selected.length)
  return selected.map((market, index) => ({
    marketSlug: market.slug,
    amountUsd: amounts[index]!,
  }))
}

type BucketKey = "liquid" | "collateral" | "lend" | "multiply"

/** A candidate market plus the price its chosen leg would be valued at, for completeness checks. */
export type StarterPricedMarket = StarterMarket & { priceUsd?: number }

/** Human-readable scope → bucket label for error messages. */
const SCOPE_TO_BUCKET: Record<StarterMarket["scope"], BucketKey> = {
  asset: "liquid",
  pool: "collateral",
  lend: "lend",
  multiply: "multiply",
}

/**
 * FAIL-CLOSED catalog gate for the claim path: onboarding must never mark a wallet "done" on a
 * partial seed, which would permanently lock it out of a real allocation. Asserts every
 * starter bucket has enough candidates for its `STARTER_BUCKETS.*.count` and that each leg the
 * plan would select carries a positive price, throwing `ONBOARDING_CATALOG_INCOMPLETE` so the
 * caller aborts before any write and the wallet stays claimable.
 * `buildStarterAllocationPlan` still degrades gracefully for its other callers.
 */
export function assertCatalogCanSatisfyStarter(wallet: string, markets: readonly StarterPricedMarket[]): void {
  const byScope = (scope: StarterMarket["scope"]) =>
    markets
      .filter((market) => market.scope === scope)
      .slice()
      .sort((left, right) => left.slug.localeCompare(right.slug))

  // 1) Every bucket must have at least its required number of candidate markets.
  const bucketReqs: Array<{ scope: StarterMarket["scope"]; count: number }> = [
    { scope: "asset", count: STARTER_BUCKETS.liquid.count },
    { scope: "pool", count: STARTER_BUCKETS.collateral.count },
    { scope: "lend", count: STARTER_BUCKETS.lend.count },
    { scope: "multiply", count: STARTER_BUCKETS.multiply.count },
  ]
  for (const req of bucketReqs) {
    const available = byScope(req.scope).length
    if (available < req.count) {
      throw codedError(
        `ONBOARDING_CATALOG_INCOMPLETE: ${SCOPE_TO_BUCKET[req.scope]} bucket needs ${req.count} ${req.scope} markets, found ${available}.`,
      )
    }
  }

  // 2) Every selected leg needs a positive price: zero/absent would seed a $0-valued or
  //    divide-by-zero position, so count it as incomplete.
  const priceBySlug = new Map(markets.map((market) => [market.slug, market.priceUsd]))
  const plan = buildStarterAllocationPlan(
    wallet,
    markets.map((market) => ({ slug: market.slug, scope: market.scope })),
  )
  const chosen = [...plan.liquid, ...plan.collateral, ...plan.lend, ...plan.multiply]
  for (const leg of chosen) {
    const price = priceBySlug.get(leg.marketSlug)
    if (price === undefined || !(price > 0) || !Number.isFinite(price)) {
      throw codedError(
        `ONBOARDING_CATALOG_INCOMPLETE: selected market "${leg.marketSlug}" has no positive price (got ${String(price)}).`,
      )
    }
  }
}

export function buildStarterAllocationPlan(wallet: string, markets: readonly StarterMarket[]): StarterAllocationPlan {
  const normalizedWallet = wallet.toLowerCase()
  const seed = hashWallet(normalizedWallet)
  const byScope = (scope: StarterMarket["scope"]) =>
    markets
      .filter((market) => market.scope === scope)
      .slice()
      .sort((left, right) => left.slug.localeCompare(right.slug))

  const plan: StarterAllocationPlan = {
    version: 1,
    wallet: normalizedWallet,
    totalEquityUsd: STARTER_EQUITY_USD,
    liquid: [],
    collateral: [],
    lend: [],
    multiply: [],
  }

  const bucketDefs: Array<{
    key: BucketKey
    scope: StarterMarket["scope"]
    target: number
    count: number
    seed: number
  }> = [
    {
      key: "liquid",
      scope: "asset",
      target: STARTER_BUCKETS.liquid.amountUsd,
      count: STARTER_BUCKETS.liquid.count,
      seed,
    },
    {
      key: "collateral",
      scope: "pool",
      target: STARTER_BUCKETS.collateral.amountUsd,
      count: STARTER_BUCKETS.collateral.count,
      seed: seed ^ 0x9e3779b9,
    },
    {
      key: "lend",
      scope: "lend",
      target: STARTER_BUCKETS.lend.amountUsd,
      count: STARTER_BUCKETS.lend.count,
      seed: seed ^ 0x85ebca6b,
    },
    {
      key: "multiply",
      scope: "multiply",
      target: STARTER_BUCKETS.multiply.amountUsd,
      count: STARTER_BUCKETS.multiply.count,
      seed: seed ^ 0xc2b2ae35,
    },
  ]

  // Never hard-fail on a scope missing from the seed: allocate across the buckets that have
  // markets and redistribute the full equity proportional to each bucket's base target. With
  // every scope present this reproduces the original per-bucket amounts exactly.
  const available = bucketDefs
    .map((def) => ({ ...def, candidates: byScope(def.scope) }))
    .filter((def) => def.candidates.length > 0)
  if (available.length === 0) return plan

  const targetCents = STARTER_EQUITY_USD * 100
  const baseTotal = available.reduce((sum, def) => sum + def.target, 0)
  let assignedCents = 0
  available.forEach((def, index) => {
    const cents =
      index === available.length - 1 ? targetCents - assignedCents : Math.round((def.target / baseTotal) * targetCents)
    assignedCents += index === available.length - 1 ? 0 : cents
    plan[def.key] = allocateBucket(def.candidates, cents / 100, def.count, def.seed)
  })

  const total = [...plan.liquid, ...plan.collateral, ...plan.lend, ...plan.multiply].reduce(
    (sum, leg) => sum + leg.amountUsd,
    0,
  )
  if (Math.round(total * 100) !== targetCents) {
    throw codedError(`STARTER_ALLOCATION_INVALID: expected ${STARTER_EQUITY_USD}, received ${total}.`)
  }
  return plan
}
