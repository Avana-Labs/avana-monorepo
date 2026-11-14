import {
  BORROW_POOL_CATALOG,
  BORROW_SPOKES,
  BORROWABLE_ASSETS,
  type BorrowPoolRow,
  type BorrowSpoke,
  type BorrowSpokeId,
  type BorrowableAsset,
  type BorrowableAssetCategory,
} from "@/app/lib/borrow-sim"

type BorrowBaseAssetDefinition = {
  id: string
  symbol: string
  name: string
  subtitle: string
  category: BorrowableAssetCategory
  visual: BorrowableAsset["visual"]
  walletBalanceLabel: string
  hasWalletBalance: boolean
}

type BorrowSpokeRecord = BorrowSpoke & {
  slug: string
  collateralMarketIds: string[]
  borrowableIds: string[]
}

export type BorrowMarketRecord = BorrowPoolRow & {
  spokeId: BorrowSpokeId
  slug: string
}

export type SpokeBorrowableRecord = BorrowableAsset & {
  baseAssetId: string
  spokeId: BorrowSpokeId
  spokeSlug: string
  spokeLabel: string
  slug: string
  contextLabel: string
  marketIds: string[]
}

export const SPOKE_SLUGS: Record<BorrowSpokeId, string> = {
  "uni-v2": "uniswap-v2",
  "uni-v3-stable": "uniswap-stable",
  "uni-v3-bluechip": "uniswap-bluechip",
  "uni-v3-gov": "uniswap-governance",
  "curve-stable": "curve-stable",
  "curve-correlated": "curve-correlated",
  "curve-crypto": "curve-crypto",
  "bal-stable": "balancer-stable",
  "bal-correlated": "balancer-correlated",
  "bal-weighted": "balancer-weighted",
  "bal-boosted": "balancer-boosted",
  "bal-reclamm": "balancer-reclamm",
  "aero-basic-stable": "aerodrome-stable",
  "aero-basic-volatile": "aerodrome-volatile",
  "aero-slipstream-bluechip": "aerodrome-bluechip",
  "aero-concentrated-stocks": "aerodrome-concentrated-10",
  "uni-robinhood-stocks": "uniswap-robinhood-stocks",
}

function seededUnit(input: string) {
  let hash = 2166136261
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return ((hash >>> 0) % 10_000) / 10_000
}

function roundUsd(value: number) {
  return Math.max(1_000, Math.round(value / 1_000) * 1_000)
}

function roundRate(value: number) {
  return Math.round(value * 100) / 100
}

function normalizeSymbol(value: string) {
  return value.toLowerCase()
}

function buildBaseAssetDefinitions() {
  return BORROWABLE_ASSETS.map((asset) => ({
    id: asset.id,
    symbol: asset.symbol,
    name: asset.name,
    subtitle: asset.subtitle,
    category: asset.category,
    visual: asset.visual,
    walletBalanceLabel: asset.walletBalanceLabel,
    hasWalletBalance: asset.hasWalletBalance,
  }))
}

function buildSpokeBorrowableRecord(
  spoke: BorrowSpoke,
  baseAsset: BorrowBaseAssetDefinition,
  marketIds: string[],
): SpokeBorrowableRecord {
  const id = `${spoke.id}:${baseAsset.id}`
  const availabilitySeed = seededUnit(`${id}:available`)
  const borrowSeed = seededUnit(`${id}:borrow`)
  const aprSeed = seededUnit(`${id}:apr`)
  const trendSeed = seededUnit(`${id}:trend`)
  const spokeMarkets = BORROW_POOL_CATALOG.filter(
    (market) => market.spoke === spoke.id && marketIds.includes(market.id),
  )
  const spokeLiquidityUsd = spokeMarkets.reduce((sum, market) => sum + market.availableUsd, 0)
  const avgLiquidityUsd =
    spokeMarkets.length > 0
      ? spokeLiquidityUsd / spokeMarkets.length
      : spoke.liquidityUsd / Math.max(marketIds.length, 1)
  const totalCapacityUsd = roundUsd(avgLiquidityUsd * (0.9 + availabilitySeed * 0.8))
  const utilization = Math.min(
    94,
    Math.max(16, Math.round(baseAsset.category === "stable" ? 54 + borrowSeed * 28 : 38 + borrowSeed * 42)),
  )
  const totalBorrowedUsd = roundUsd(totalCapacityUsd * (utilization / 100))
  const availableUsd = roundUsd(totalCapacityUsd)
  const borrowApr = roundRate(
    (BORROWABLE_ASSETS.find((asset) => asset.id === baseAsset.id)?.borrowApr ?? spoke.aprApprox) +
      (spoke.aprApprox - 4) * 0.22 +
      (aprSeed - 0.5) * 0.9,
  )

  return {
    id,
    baseAssetId: baseAsset.id,
    spokeId: spoke.id,
    spokeSlug: SPOKE_SLUGS[spoke.id],
    spokeLabel: spoke.label,
    slug: baseAsset.id,
    contextLabel: `${baseAsset.name} on ${spoke.label}`,
    marketIds,
    symbol: baseAsset.symbol,
    name: baseAsset.name,
    subtitle: `${baseAsset.subtitle} · ${spoke.label}`,
    borrowApr: Math.max(0.25, borrowApr),
    totalBorrowedUsd,
    utilization,
    availableUsd,
    walletBalanceLabel: baseAsset.walletBalanceLabel,
    hasWalletBalance: baseAsset.hasWalletBalance,
    visual: baseAsset.visual,
    trendUp: trendSeed >= 0.45,
    trendValues: [0.92, 0.97, 1.01, 0.99, 1.04].map((value) => Number((value * Math.max(utilization, 1)).toFixed(2))),
    category: baseAsset.category,
  }
}

function buildRegistry() {
  const baseAssets = buildBaseAssetDefinitions()
  const baseAssetBySymbol = new Map(baseAssets.map((asset) => [normalizeSymbol(asset.symbol), asset]))
  const markets: BorrowMarketRecord[] = BORROW_POOL_CATALOG.map((market) => ({
    ...market,
    spokeId: market.spoke,
    slug: market.id,
  }))
  const marketsBySpoke = new Map<BorrowSpokeId, BorrowMarketRecord[]>()

  for (const market of markets) {
    const rows = marketsBySpoke.get(market.spokeId) ?? []
    rows.push(market)
    marketsBySpoke.set(market.spokeId, rows)
  }

  const spokes: BorrowSpokeRecord[] = BORROW_SPOKES.map((spoke) => {
    const spokeMarkets = marketsBySpoke.get(spoke.id) ?? []
    const borrowableIds = spoke.borrowableTokens
      .map((token) => baseAssetBySymbol.get(normalizeSymbol(token.symbol)))
      .filter((asset): asset is BorrowBaseAssetDefinition => Boolean(asset))
      .map((asset) => `${spoke.id}:${asset.id}`)

    return {
      ...spoke,
      slug: SPOKE_SLUGS[spoke.id],
      collateralMarketIds: spokeMarkets.map((market) => market.id),
      borrowableIds,
    }
  })

  const borrowables: SpokeBorrowableRecord[] = []
  for (const spoke of BORROW_SPOKES) {
    const spokeMarkets = marketsBySpoke.get(spoke.id) ?? []
    const marketIds = spokeMarkets.map((market) => market.id)
    for (const token of spoke.borrowableTokens) {
      const asset = baseAssetBySymbol.get(normalizeSymbol(token.symbol))
      if (!asset) continue
      borrowables.push(buildSpokeBorrowableRecord(spoke, asset, marketIds))
    }
  }

  return {
    baseAssets,
    spokes,
    markets,
    borrowables,
  }
}

const registry = buildRegistry()

export function listBorrowSpokes() {
  return [...registry.spokes]
}

export function listBorrowMarkets() {
  return [...registry.markets]
}

export function listSpokeBorrowables() {
  return [...registry.borrowables]
}

export function getBorrowSpoke(idOrSlug: string) {
  return registry.spokes.find((spoke) => spoke.id === idOrSlug || spoke.slug === idOrSlug) ?? null
}

export function getSpokeBorrowable(id: string) {
  return registry.borrowables.find((borrowable) => borrowable.id === id) ?? null
}

export function resolveSpokeBorrowable(idOrBaseAsset: string) {
  if (idOrBaseAsset.includes(":")) return getSpokeBorrowable(idOrBaseAsset)

  const matches = registry.borrowables.filter(
    (borrowable) =>
      borrowable.baseAssetId === idOrBaseAsset || normalizeSymbol(borrowable.symbol) === normalizeSymbol(idOrBaseAsset),
  )

  return matches.sort((left, right) => right.availableUsd - left.availableUsd)[0] ?? null
}
