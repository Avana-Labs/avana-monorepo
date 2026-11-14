import {
  RAY,
  parseFixed,
  type BorrowAssetRecord,
  type BorrowMarketRecord,
  type BorrowMetricSeries,
  type BorrowSystemState,
  type BorrowVisual,
} from "@/app/lib/borrow-system/model"
import { getTokenIconMeta } from "@/app/lib/token-icons"

/**
 * One Borrow row from services/convex `markets.listMarketSnapshots`: a collateral market
 * (`pool`, one per marketId) or a CDP Spoke debt reserve (`asset`). Loose `scope: string` so the
 * raw query result (which also carries lend rows) is assignable without a cast.
 */
export type ConvexMarketSnapshot = {
  slug: string
  scope: string
  name?: string
  symbol?: string
  chainId?: number
  venueLabel?: string
  category?: string
  description?: string
  spokeId?: string
  hubId?: string
  hubLabel?: string
  feeTier?: string
  maxLtvPct?: number
  premiumBps?: number
  reserveFactorPct?: number
  visuals?: ReadonlyArray<{
    symbol: string
    shortLabel: string
    bgClassName: string
    textClassName: string
    iconUrl?: string
  }>
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
  tvlUsd: number
  volumeUsd: number
  feesUsd: number
  /** Pools: the market's accepted LP price (LPOracle). */
  lpPriceUsd?: number
}

const CHAIN_LABELS: Record<number, string> = { 1: "Ethereum", 8453: "Base", 31337: "Local" }

export function chainLabel(chainId: number | undefined): string {
  return chainId !== undefined ? (CHAIN_LABELS[chainId] ?? `Chain ${chainId}`) : "—"
}

function usd6(value: number | undefined) {
  return parseFixed(Math.max(0, Number.isFinite(value) ? (value as number) : 0).toFixed(6), 6)
}

function wadFromPct(pct: number | undefined) {
  return parseFixed((Math.max(0, Number.isFinite(pct) ? (pct as number) : 0) / 100).toFixed(18), 18)
}

function finite(value: number | undefined): number | undefined {
  return value !== undefined && Number.isFinite(value) ? value : undefined
}

function visualFor(symbol: string): BorrowVisual {
  return {
    symbol,
    shortLabel: symbol.slice(0, 4),
    iconUrl: getTokenIconMeta(symbol).iconUrl ?? null,
    bgClassName: "bg-muted",
    textClassName: "text-foreground",
  }
}

function pairVisuals(snap: ConvexMarketSnapshot): [BorrowVisual, BorrowVisual] {
  const listed = snap.visuals ?? []
  if (listed.length >= 2) {
    const [a, b] = listed
    return [
      { ...a, iconUrl: a.iconUrl ?? getTokenIconMeta(a.symbol).iconUrl ?? null },
      { ...b, iconUrl: b.iconUrl ?? getTokenIconMeta(b.symbol).iconUrl ?? null },
    ]
  }
  const parts = (snap.name ?? snap.symbol ?? snap.slug)
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean)
  const first = parts[0] ?? snap.symbol ?? snap.slug
  return [visualFor(first), visualFor(parts[1] ?? first)]
}

function emptySeries(label: string, unit: BorrowMetricSeries["unit"]): BorrowMetricSeries {
  return { label, unit, points: [] }
}

function category(value: string | undefined, symbol: string): BorrowAssetRecord["display"]["category"] {
  if (value === "stable") return "stable"
  const upper = symbol.toUpperCase()
  if (upper.includes("BTC")) return "btc"
  if (upper.includes("ETH")) return "eth"
  return "crypto"
}

/** A collateral market as services/convex reports it. Fields it does not report stay empty. */
export function borrowMarketFromSnapshot(
  snap: ConvexMarketSnapshot,
  related: readonly ConvexMarketSnapshot[],
): BorrowMarketRecord {
  const visuals = pairVisuals(snap)
  const cf = wadFromPct(snap.maxLtvPct)
  const spokeId = snap.spokeId ?? ""
  return {
    id: snap.slug,
    spokeId,
    display: {
      name: snap.name?.trim() || `${visuals[0].symbol} / ${visuals[1].symbol}`,
      lpSymbol: snap.symbol?.trim() || `${visuals[0].symbol}-${visuals[1].symbol}`,
      venue: snap.venueLabel ?? "",
      chain: chainLabel(snap.chainId),
      feeTier: snap.feeTier ?? "",
      subtitle: snap.venueLabel ?? "",
      visuals,
    },
    // Aave V4: the liquidation threshold equals the collateral factor (REQ-LENS-045).
    riskConfig: { collateralFactorWad: cf, liquidationThresholdWad: cf, riskScoreWad: 0n },
    listPremiumBps: finite(snap.premiumBps),
    reserveFactorPct: finite(snap.reserveFactorPct),
    relations: {
      supportedBorrowAssetIds: related
        .filter((row) => row.scope === "asset" && sameSpokeOrChain(row, snap))
        .map((row) => row.slug),
      relatedMarketIds: related
        .filter((row) => row.scope === "pool" && row.slug !== snap.slug && row.spokeId === snap.spokeId)
        .map((row) => row.slug),
    },
    snapshot: {
      lpTokenPriceUsd6: usd6(snap.lpPriceUsd),
      feeApyWad: wadFromPct(snap.supplyApyPct),
      totalLiquidityUsd6: usd6(snap.tvlUsd),
      totalBorrowedUsd6: usd6(snap.borrowedUsd),
      availableUsd6: usd6(snap.availableUsd),
      volume24hUsd6: usd6(snap.volumeUsd),
      fees24hUsd6: usd6(snap.feesUsd),
      totalCollateralShares: 0n,
      supplyIndexRay: RAY,
    },
    detail: { about: snap.description ?? "", faqs: [], parameterChanges: [], governanceNotes: [] },
    analytics: {
      keyMetrics: {},
      cashflow: emptySeries("Cashflow", "usd"),
      engagement: emptySeries("Engagement", "count"),
    },
  }
}

/**
 * services/convex reports a pool row's Spoke by address and an asset row's Spoke by its slug, so
 * the two only match when both use the same key; otherwise the debt reserves of the same chain
 * are offered (one CDP Spoke per chain at launch).
 */
function sameSpokeOrChain(asset: ConvexMarketSnapshot, pool: ConvexMarketSnapshot) {
  if (asset.spokeId && pool.spokeId && asset.spokeId === pool.spokeId) return true
  return asset.chainId !== undefined && asset.chainId === pool.chainId
}

/** A CDP Spoke debt reserve as services/convex reports it. */
export function borrowAssetFromSnapshot(
  snap: ConvexMarketSnapshot,
  related: readonly ConvexMarketSnapshot[],
): BorrowAssetRecord {
  const symbol = snap.symbol?.trim() || snap.slug.toUpperCase()
  const borrowed = usd6(snap.borrowedUsd)
  return {
    id: snap.slug,
    baseAssetId: symbol.toLowerCase(),
    spokeId: snap.spokeId ?? "",
    marketIds: related.filter((row) => row.scope === "pool" && sameSpokeOrChain(snap, row)).map((row) => row.slug),
    slug: snap.slug,
    contextLabel: snap.hubLabel ?? snap.venueLabel ?? "",
    symbol,
    display: {
      name: snap.name?.trim() || symbol,
      subtitle: snap.hubLabel ?? "",
      chain: chainLabel(snap.chainId),
      category: category(snap.category, symbol),
      visual: snap.visuals?.[0]
        ? { ...snap.visuals[0], iconUrl: snap.visuals[0].iconUrl ?? getTokenIconMeta(symbol).iconUrl ?? null }
        : visualFor(symbol),
    },
    borrowConfig: { baseBorrowAprWad: wadFromPct(snap.borrowAprPct) },
    reserveFactorPct: finite(snap.reserveFactorPct),
    snapshot: {
      priceUsd6: 0n,
      priceChange24hWad: 0n,
      availableLiquidityUsd6: usd6(snap.availableUsd),
      totalBorrowedUsd6: borrowed,
      totalDebtSharesUsd6: borrowed,
    },
    detail: { about: snap.description ?? "", faqs: [] },
    analytics: { utilization: emptySeries("Utilization", "pct"), supplyBorrow: {} },
  }
}

/**
 * Replace the Borrow markets and debt reserves of a state with what services/convex reports, so
 * lists, detail pages and the action pages all read the markets listed on chain and nothing else.
 * Wallet accounts are untouched. Returns the SAME state reference when nothing changed.
 */
export function mergeConvexMarketSnapshots(
  state: BorrowSystemState,
  snapshots: readonly ConvexMarketSnapshot[],
): BorrowSystemState {
  const rows = snapshots.filter((snap) => snap.scope === "pool" || snap.scope === "asset")
  if (rows.length === 0) return state
  const markets: Record<string, BorrowMarketRecord> = {}
  const assets: Record<string, BorrowAssetRecord> = {}
  for (const snap of rows) {
    if (snap.scope === "pool") markets[snap.slug] = borrowMarketFromSnapshot(snap, rows)
    else assets[snap.slug] = borrowAssetFromSnapshot(snap, rows)
  }
  const key = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v))
  if (key(markets) === key(state.markets) && key(assets) === key(state.assets)) return state
  return { ...state, markets, assets }
}

/** A Borrow state with no markets yet and an empty account for the wallet. */
export function emptyBorrowSystemState(walletId: string, now = Date.now()): BorrowSystemState {
  return {
    now,
    markets: {},
    assets: {},
    accounts: {
      [walletId]: {
        walletId,
        walletBalanceUsd6: 0n,
        walletLpBalancesUsd6: {},
        interestSettledUsd6: 0n,
        lastUpdatedAt: now,
        collateralPositions: [],
        debtPositions: [],
        rewardPositions: [],
      },
    },
    transactions: [],
  }
}
