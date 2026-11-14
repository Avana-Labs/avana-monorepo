import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import {
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  formatFixed,
} from "@/app/lib/borrow-system/model"
import { formatActionUsd } from "@/app/lib/action-system/formatters"
import { selectRewardClaimableTotals } from "@/app/lib/borrow-system/home-runtime"
import { formatBorrowMarketContext } from "@/app/lib/borrow-system/market-labels"
import { getWalletLpBalanceUsd } from "@/app/lib/borrow-system/wallet-lp-balances"

function normalizeBorrowAssetKey(value: string) {
  return value.trim().toLowerCase()
}

/** Map short route params (`usdc`) to scoped engine asset ids (`uni-v3-bluechip:usdc`). */
export function resolveBorrowAssetId(state: BorrowSystemState, rawAssetId: string, marketId?: string) {
  const trimmed = rawAssetId.trim()
  if (!trimmed) return trimmed

  const normalized = normalizeBorrowAssetKey(trimmed)

  const matchesNormalized = (assetId: string) => {
    const asset = state.assets[assetId]
    if (!asset) return false
    return (
      normalizeBorrowAssetKey(asset.id) === normalized ||
      normalizeBorrowAssetKey(asset.baseAssetId) === normalized ||
      normalizeBorrowAssetKey(asset.symbol) === normalized ||
      asset.id.toLowerCase().endsWith(`:${normalized}`)
    )
  }

  if (marketId) {
    const market = state.markets[marketId]
    if (market) {
      const asset = state.assets[trimmed]
      if (asset && asset.spokeId === market.spokeId && market.relations.supportedBorrowAssetIds.includes(trimmed)) {
        return trimmed
      }

      const scoped = `${market.spokeId}:${normalized}`
      if (state.assets[scoped] && market.relations.supportedBorrowAssetIds.includes(scoped)) {
        return scoped
      }

      const supported = market.relations.supportedBorrowAssetIds.find((assetId) => matchesNormalized(assetId))
      if (supported) return supported
    }

    return ""
  }

  if (state.assets[trimmed]) return trimmed

  const direct = Object.values(state.assets).find((asset) => normalizeBorrowAssetKey(asset.id) === normalized)
  if (direct) return direct.id

  const fallback = Object.values(state.assets).find((asset) => {
    return (
      normalizeBorrowAssetKey(asset.baseAssetId) === normalized ||
      normalizeBorrowAssetKey(asset.symbol) === normalized ||
      asset.id.toLowerCase().endsWith(`:${normalized}`)
    )
  })

  return fallback?.id ?? (state.assets[trimmed] ? trimmed : "")
}

type BorrowContextSession = {
  state: BorrowSystemState
  marketSummaries: Array<{
    id: string
    name: string
    venue: string
    feeTier: string
  }>
  collateralPools: Array<{ id: string }>
  getBorrowableAssetsForMarket: (marketId?: string) => Array<{
    id: string
    name: string
    symbol: string
    borrowApr: number
  }>
  borrowableAssets: Array<{
    id: string
    name: string
    symbol: string
    borrowApr: number
  }>
}

function assetAvailableUsd(state: BorrowSystemState, assetId: string) {
  const asset = state.assets[assetId]
  if (!asset) return null
  return Number.parseFloat(formatFixed(asset.snapshot.availableLiquidityUsd6, 6))
}

function borrowMarketCandidates(session: BorrowContextSession, preferredMarketId?: string) {
  return [
    preferredMarketId,
    ...session.collateralPools.map((pool) => pool.id),
    ...session.marketSummaries.map((market) => market.id),
  ].filter((marketId, index, entries): marketId is string => Boolean(marketId) && entries.indexOf(marketId) === index)
}

function resolveBorrowSelectionInMarket(session: BorrowContextSession, tokenId: string, marketId: string) {
  const assetId = resolveBorrowAssetId(session.state, tokenId, marketId)
  if (!assetId) return null

  const market = session.state.markets[marketId]
  if (!market?.relations.supportedBorrowAssetIds.includes(assetId)) return null

  return {
    assetId,
    marketId,
  }
}

export function resolveBorrowMarketForAsset(
  session: BorrowContextSession,
  assetId: string,
  preferredMarketId?: string,
) {
  const scopedAsset = session.state.assets[assetId]
  // The base token (`usdc`) re-scopes cleanly into any market's spoke; the full
  // scoped id (`uni-v3-stable:usdc`) does not, so match the explicit choice on it.
  const baseToken = scopedAsset?.baseAssetId ?? assetId

  // Honor an explicit, valid market choice first (e.g. the user picked a
  // collateral pool). Re-scoping the debt to that market's spoke is intentional
  // when the user changes venue.
  if (preferredMarketId && resolveBorrowSelectionInMarket(session, baseToken, preferredMarketId)) {
    return preferredMarketId
  }

  // Otherwise keep a venue-scoped asset on its OWN venue. Borrowing
  // `uni-v3-stable:usdt` must default to a uni-v3-stable collateral market — not
  // whatever `:usdt` pool happens to sort first (which would silently re-scope
  // the debt to e.g. `curve-stable:usdt` and surface it on the wrong asset page).
  if (scopedAsset) {
    for (const marketId of borrowMarketCandidates(session, preferredMarketId)) {
      const market = session.state.markets[marketId]
      if (
        market &&
        market.spokeId === scopedAsset.spokeId &&
        market.relations.supportedBorrowAssetIds.includes(assetId)
      ) {
        return marketId
      }
    }
  }

  for (const marketId of borrowMarketCandidates(session, preferredMarketId)) {
    if (resolveBorrowSelectionInMarket(session, assetId, marketId)) {
      return marketId
    }
  }

  const resolvedAssetId = resolveBorrowAssetId(session.state, assetId)
  if (resolvedAssetId) {
    const market = Object.values(session.state.markets).find((entry) =>
      entry.relations.supportedBorrowAssetIds.includes(resolvedAssetId),
    )
    if (market) return market.id
  }

  return preferredMarketId ?? session.collateralPools[0]?.id ?? ""
}

export function resolveBorrowTokenSelection(
  session: BorrowContextSession,
  tokenId: string,
  preferredMarketId?: string,
) {
  for (const marketId of borrowMarketCandidates(session, preferredMarketId)) {
    const selection = resolveBorrowSelectionInMarket(session, tokenId, marketId)
    if (selection) return selection
  }

  return null
}

export function supplySelectItemsForWallet(session: BorrowContextSession, walletId: string) {
  return session.marketSummaries
    .map((pool) => {
      const market = session.state.markets[pool.id]
      const walletLpUsd = getWalletLpBalanceUsd(session.state, walletId, pool.id)
      const visuals = market?.display.visuals ?? []
      return {
        id: pool.id,
        name: pool.name,
        symbol: visuals[0]?.symbol ?? pool.name.split("/")[0]?.trim() ?? "LP",
        pairSymbols: visuals.length >= 2 ? ([visuals[0]!.symbol, visuals[1]!.symbol] as [string, string]) : undefined,
        sublabel: formatBorrowMarketContext({ venue: pool.venue, feeTier: pool.feeTier }),
        trailingLabel: formatActionUsd(walletLpUsd),
        walletLpUsd,
      }
    })
    .filter((item) => item.walletLpUsd > 0)
    .map(({ walletLpUsd: _walletLpUsd, ...item }) => item)
}

export function removeSelectItemsForWallet(session: BorrowContextSession, walletId: string) {
  const account = session.state.accounts[walletId]
  if (!account) return []

  return account.collateralPositions
    .map((position) => {
      const market = session.state.markets[position.marketId]
      if (!market) return null
      const visuals = market.display.visuals ?? []
      const collateralUsd = Number.parseFloat(formatFixed(currentCollateralValueUsd6(position, market), 6))
      return {
        id: market.id,
        name: market.display.name,
        symbol: visuals[0]?.symbol ?? market.display.name.split("/")[0]?.trim() ?? "LP",
        pairSymbols: visuals.length >= 2 ? ([visuals[0]!.symbol, visuals[1]!.symbol] as [string, string]) : undefined,
        sublabel: formatBorrowMarketContext({ venue: market.display.venue, feeTier: market.display.feeTier }),
        trailingLabel: formatActionUsd(collateralUsd),
        collateralUsd,
      }
    })
    .filter((item): item is NonNullable<typeof item> => Boolean(item && item.collateralUsd > 0))
    .map(({ collateralUsd: _collateralUsd, ...item }) => item)
}

export function borrowSelectItemsForMarket(
  session: BorrowContextSession,
  marketId: string | undefined,
  _walletId: string,
) {
  const assets = marketId ? session.getBorrowableAssetsForMarket(marketId) : session.borrowableAssets
  return assets.map((asset) => {
    // Show the asset's OWN available liquidity — a genuinely per-asset figure.
    // The account's borrowing power is a single global cap (identical across every
    // asset) and is surfaced separately in the configure step, so pinning it here
    // made every row read the same "$X available".
    const liquidityUsd = assetAvailableUsd(session.state, asset.id)
    // The same asset is borrowable in several spokes (USD Coin appeared twice for guests), so
    // name the spoke. "liquidity" because "available" read as the wallet's own borrow limit.
    const spokeId = session.state.assets[asset.id]?.spokeId ?? asset.id.split(":")[0]
    return {
      id: asset.id,
      name: asset.name,
      symbol: asset.symbol,
      sublabel: session.state.assets[asset.id]?.contextLabel || spokeId || asset.symbol,
      trailingLabel:
        liquidityUsd != null
          ? `${formatActionUsd(liquidityUsd, { compact: true })} liquidity`
          : `${asset.borrowApr.toFixed(2)}% APR`,
    }
  })
}

export function claimSelectItemsForWallet(session: BorrowContextSession, walletId: string) {
  const account = session.state.accounts[walletId]
  if (!account) return []

  const claimableById = selectRewardClaimableTotals(session.state, walletId)

  return account.rewardPositions
    .map((position) => {
      const market = session.state.markets[position.marketId]
      const claimableUsd = claimableById[position.id] ?? 0

      return {
        id: position.id,
        name: market?.display.name ?? position.marketId,
        symbol: market?.display.visuals?.[0]?.symbol ?? "Fees",
        trailingLabel: `${formatActionUsd(claimableUsd)} claimable`,
        claimableUsd,
        marketId: position.marketId,
      }
    })
    .filter((item) => item.claimableUsd > 0)
}

export function resolveClaimMarketId(marketOrPoolId: string) {
  return marketOrPoolId
}

export function repaySelectItemsForWallet(session: BorrowContextSession, walletId: string, now = Date.now()) {
  // Owed = principal plus interest accrued since the last write, the figure the dashboard shows.
  const account = session.state.accounts[walletId]
  if (!account) return []

  return account.debtPositions.map((position) => {
    const asset = session.state.assets[position.assetId]
    const debtUsd = Number.parseFloat(formatFixed(currentDebtValueUsd6(position), 6))

    return {
      id: position.id,
      name: asset?.display?.name ?? asset?.symbol ?? "Debt position",
      symbol: asset?.symbol ?? "Asset",
      trailingLabel: `${formatActionUsd(debtUsd)} owed`,
    }
  })
}
