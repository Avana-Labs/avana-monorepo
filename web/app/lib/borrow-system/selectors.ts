import {
  calculateCreditMetrics,
  calculateSpokeCreditMetrics,
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  formatFixed,
  totalDebtValueUsd6,
  type BorrowSystemState,
} from "@/app/lib/borrow-system/model"
import type { BorrowAssetVisual, BorrowPoolRow, BorrowableAsset } from "@/app/lib/borrow-market-rows"
import { normalizeWeights } from "@/app/lib/prices/lp-token-price"
import type { HomeCollateralPool } from "@/app/lib/borrow-system/home-contracts"
import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

/**
 * Single source of truth for a borrowable asset's displayed/paid borrow APR:
 * the base borrow rate PLUS the risk premium. The borrow list, the dashboard debt
 * rows, and the action page all resolve the headline rate through this one helper so
 * they can never drift to base-only on one surface and base+premium on another (C2).
 */
export function resolveBorrowAprPct(baseBorrowAprWad: bigint, riskPremiumWad: bigint): number {
  return fixedToNumber(baseBorrowAprWad + riskPremiumWad, 18) * 100
}

function visualToUi(visual: BorrowSystemState["markets"][string]["display"]["visuals"][number]): BorrowAssetVisual {
  return {
    symbol: visual.symbol,
    shortLabel: visual.shortLabel,
    // Convex may retain an old `.svg` URL after the bundled catalog moved to
    // PNG. Resolve by symbol at the rendering boundary so stale seed metadata
    // cannot turn every Borrow row into a 404 request.
    iconUrl: getLocalAssetIcon(visual.symbol),
    bgClass: visual.bgClassName,
    textClass: visual.textClassName,
  }
}

const FALLBACK_VISUAL: BorrowAssetVisual = {
  symbol: "—",
  shortLabel: "—",
  iconUrl: undefined,
  bgClass: "bg-muted",
  textClass: "text-muted-foreground",
}

// Market rows are rendered as a two-token pair (visuals[0]/visuals[1]). A market
// that arrives with fewer than two visuals (single-token or malformed data from
// hydration) would otherwise crash the entire client-rendered workspace on an
// unguarded `visuals[1].symbol` access. Always return a well-formed 2-tuple.
export function toPairVisuals(visuals: BorrowAssetVisual[]): [BorrowAssetVisual, BorrowAssetVisual] {
  return [visuals[0] ?? FALLBACK_VISUAL, visuals[1] ?? visuals[0] ?? FALLBACK_VISUAL]
}

function venueChipLabel(venue: string) {
  if (venue.toLowerCase().includes("uniswap")) return "Uniswap"
  if (venue.toLowerCase().includes("aerodrome")) return "Aerodrome"
  return venue || "—"
}

function slugify(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
}

function marketDebtUsd6(state: BorrowSystemState, walletId: string, marketId: string) {
  const account = state.accounts[walletId]
  if (!account) return 0n
  const spokeId = state.markets[marketId]?.spokeId
  if (!spokeId) return 0n
  return account.debtPositions
    .filter((position) => position.spokeId === spokeId)
    .reduce((sum, position) => sum + currentDebtValueUsd6(position), 0n)
}

export function selectBorrowMarketSummaries(state: BorrowSystemState, walletId: string): BorrowPoolRow[] {
  const account = state.accounts[walletId]

  return Object.values(state.markets).map((market) => {
    const position = account?.collateralPositions.find((row) => row.marketId === market.id)
    const positionUsd = position ? fixedToNumber(currentCollateralValueUsd6(position, market), 6) : 0
    const feeApyPct = fixedToNumber(market.snapshot.feeApyWad, 18) * 100
    // The market's collateral risk (borrow-rate premium) as services/convex reports it.
    const riskPremiumBps = market.listPremiumBps ?? Number.NaN
    const dexLabel = venueChipLabel(market.display.venue)

    return {
      id: market.id,
      name: market.display.name,
      venue: market.display.venue,
      feeTier: market.display.feeTier,
      tvlUsd: fixedToNumber(market.snapshot.totalLiquidityUsd6, 6),
      change24hPct:
        market.snapshot.totalLiquidityUsd6 > 0n
          ? fixedToNumber((market.snapshot.fees24hUsd6 * 10_000n) / market.snapshot.totalLiquidityUsd6, 2)
          : 0,
      spoke: market.spokeId,
      spokeLabel: market.display.venue || market.spokeId,
      dexId: slugify(dexLabel) || "dex",
      dexLabel,
      chain: market.display.chain,
      ltv: Math.round(fixedToNumber(market.riskConfig.collateralFactorWad, 18) * 1000) / 10,
      dexes: [{ id: slugify(dexLabel) || "dex", label: dexLabel }],
      borrowableTokens: market.relations.supportedBorrowAssetIds
        .map((assetId) => state.assets[assetId])
        .filter((asset): asset is NonNullable<typeof asset> => Boolean(asset))
        .slice(0, 5)
        .map((asset) => visualToUi(asset.display.visual)),
      aprMin: feeApyPct,
      aprMax: feeApyPct,
      availableUsd: fixedToNumber(market.snapshot.availableUsd6, 6),
      capacityFilledPct:
        market.snapshot.totalLiquidityUsd6 > 0n
          ? (fixedToNumber(market.snapshot.totalBorrowedUsd6, 6) /
              fixedToNumber(market.snapshot.totalLiquidityUsd6, 6)) *
            100
          : 0,
      riskPremiumBps,
      visuals: toPairVisuals(market.display.visuals.map(visualToUi)),
      // Equal-weight display pair: collateral value comes from the market's LPOracle price, not this.
      constituents: normalizeWeights(
        toPairVisuals(market.display.visuals.map(visualToUi)).map((vis) => ({ symbol: vis.symbol, weight: 1 })),
      ),
      collateralExampleUsd: positionUsd,
      trendUp: true,
      trendValues: undefined,
      events:
        position && marketDebtUsd6(state, walletId, market.id) > 0n
          ? [{ label: "Borrow active", tone: "warning" }]
          : position
            ? [{ label: "Collateral supplied", tone: "positive" }]
            : undefined,
    }
  })
}

export function selectBorrowableAssets(
  state: BorrowSystemState,
  walletId: string,
  marketId?: string,
): BorrowableAsset[] {
  const account = state.accounts[walletId]
  const market = marketId ? state.markets[marketId] : null
  const supported = market ? new Set(market.relations.supportedBorrowAssetIds) : null
  const walletBalanceLabel = account
    ? `$${fixedToNumber(account.walletBalanceUsd6, 6).toLocaleString("en-US", { maximumFractionDigits: 0 })}`
    : "$0"

  return Object.values(state.assets)
    .filter((asset) => !supported || supported.has(asset.id))
    .map((asset) => {
      const scopedMetrics = calculateSpokeCreditMetrics(state, walletId, asset.spokeId)
      const totalLiquidityUsd = fixedToNumber(
        asset.snapshot.availableLiquidityUsd6 + asset.snapshot.totalBorrowedUsd6,
        6,
      )
      const utilization =
        totalLiquidityUsd > 0 ? (fixedToNumber(asset.snapshot.totalBorrowedUsd6, 6) / totalLiquidityUsd) * 100 : 0

      return {
        id: asset.id,
        symbol: asset.symbol,
        name: asset.display.name,
        subtitle: asset.display.subtitle,
        borrowApr: resolveBorrowAprPct(asset.borrowConfig.baseBorrowAprWad, scopedMetrics.riskPremiumWad),
        totalBorrowedUsd: fixedToNumber(asset.snapshot.totalBorrowedUsd6, 6),
        utilization,
        availableUsd: fixedToNumber(asset.snapshot.availableLiquidityUsd6, 6),
        walletBalanceLabel,
        hasWalletBalance: Boolean(account && account.walletBalanceUsd6 > 0n),
        visual: visualToUi(asset.display.visual),
        trendUp: asset.snapshot.priceChange24hWad >= 0n,
        trendValues: undefined,
        category: asset.display.category,
      }
    })
}

export function selectBorrowCollateralPools(state: BorrowSystemState, walletId: string): HomeCollateralPool[] {
  const account = state.accounts[walletId]
  if (!account) return []

  return account.collateralPositions
    .map((position) => {
      const market = state.markets[position.marketId]
      if (!market) return null
      const collateralUsd = fixedToNumber(currentCollateralValueUsd6(position, market), 6)
      return {
        id: market.id,
        name: market.display.name,
        venue: market.display.venue,
        category: `${market.display.venue} ${market.display.feeTier}`,
        collateralUsd,
        maxLtv: Math.round(fixedToNumber(market.riskConfig.collateralFactorWad, 18) * 1000) / 10,
        borrowPowerUsd: fixedToNumber(metricsForPosition(state, walletId, position.marketId).creditLimitUsd6, 6),
        liquidationUsd: fixedToNumber(metricsForPosition(state, walletId, position.marketId).liquidationValueUsd6, 6),
        pairApr: fixedToNumber(market.snapshot.feeApyWad, 18) * 100,
        visuals: market.display.visuals.map((visual) => ({
          symbol: visual.symbol,
          shortLabel: visual.shortLabel,
          bgClassName: visual.bgClassName,
          textClassName: visual.textClassName,
        })) as HomeCollateralPool["visuals"],
      }
    })
    .filter((pool): pool is HomeCollateralPool => Boolean(pool))
}

/**
 * Every listed market as a collateral pool — pledged or not. Pools the
 * wallet already holds carry their real collateral/borrow-power; the rest report
 * zero until the user pledges. The Express borrow card uses this so its pool
 * picker is always pre-loaded (a fresh wallet with no positions still sees the
 * full market list), mirroring the dashboard's borrow view.
 */
export function selectAllAvailableCollateralPools(state: BorrowSystemState, walletId: string): HomeCollateralPool[] {
  const account = state.accounts[walletId]

  return Object.values(state.markets).map((market) => {
    // Report the SPOKE-scoped in-scope collateral (not just this market's own
    // pledge) so the top Collateral card matches the "Net collateral in scope"
    // metric block: a market whose spoke already holds collateral must not show
    // $0.00 while a borrow against that scope is allowed.
    const metrics = account ? metricsForPosition(state, walletId, market.id) : null
    const collateralUsd = metrics ? fixedToNumber(metrics.poolCollateralValueUsd6, 6) : 0
    const ownCollateralUsd = (account?.collateralPositions ?? [])
      .filter((position) => position.marketId === market.id)
      .reduce((sum, position) => sum + fixedToNumber(currentCollateralValueUsd6(position, market), 6), 0)
    return {
      id: market.id,
      name: market.display.name,
      venue: market.display.venue,
      category: `${market.display.venue} ${market.display.feeTier}`,
      collateralUsd,
      ownCollateralUsd,
      maxLtv: Math.round(fixedToNumber(market.riskConfig.collateralFactorWad, 18) * 1000) / 10,
      borrowPowerUsd: metrics ? fixedToNumber(metrics.creditLimitUsd6, 6) : 0,
      liquidationUsd: metrics ? fixedToNumber(metrics.liquidationValueUsd6, 6) : 0,
      pairApr: fixedToNumber(market.snapshot.feeApyWad, 18) * 100,
      visuals: market.display.visuals.map((visual) => ({
        symbol: visual.symbol,
        shortLabel: visual.shortLabel,
        bgClassName: visual.bgClassName,
        textClassName: visual.textClassName,
      })) as HomeCollateralPool["visuals"],
    }
  })
}

function metricsForPosition(state: BorrowSystemState, walletId: string, marketId: string) {
  const base = state.accounts[walletId]
  if (!base) throw new Error(`Unknown wallet ${walletId}`)
  const spokeId = state.markets[marketId]?.spokeId
  if (!spokeId) throw new Error(`Unknown market ${marketId}`)
  const scoped: BorrowSystemState = {
    ...state,
    accounts: {
      [walletId]: {
        ...base,
        collateralPositions: base.collateralPositions.filter(
          (position) => state.markets[position.marketId]?.spokeId === spokeId,
        ),
        debtPositions: base.debtPositions.filter((position) => position.spokeId === spokeId),
      },
    },
  }
  return calculateCreditMetrics(scoped, walletId)
}

export function selectInitialBorrowDebts(state: BorrowSystemState, walletId: string) {
  const account = state.accounts[walletId]
  if (!account) return {} as Record<string, number>

  const byMarket: Record<string, number> = {}
  for (const position of account.debtPositions) {
    if (!position.marketId) continue
    byMarket[position.marketId] = (byMarket[position.marketId] ?? 0) + fixedToNumber(currentDebtValueUsd6(position), 6)
  }
  return byMarket
}

export function selectWalletBorrowSnapshot(state: BorrowSystemState, walletId: string) {
  const account = state.accounts[walletId]
  if (!account) throw new Error(`Unknown wallet ${walletId}`)
  const metrics = calculateCreditMetrics(state, walletId)
  return {
    totalBorrowedUsd: fixedToNumber(totalDebtValueUsd6(account), 6),
    availableCreditUsd: fixedToNumber(metrics.availableCreditUsd6, 6),
    totalCollateralUsd: fixedToNumber(metrics.poolCollateralValueUsd6, 6),
    liquidationValueUsd: fixedToNumber(metrics.liquidationValueUsd6, 6),
    healthFactor: metrics.healthFactorWad > 0n ? fixedToNumber(metrics.healthFactorWad, 18) : null,
  }
}
