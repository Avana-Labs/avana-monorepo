import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { formatTokenQuantity } from "@/app/lib/currency/format"
import type { MultiplyMarketRecord, MultiplySystemState } from "@/app/lib/multiply-engine"
import { calculateMaxLeverageApy, calculateMultiplyHealthFactor } from "@/app/lib/multiply-engine"
import { resolveMultiplyMarketDisplayMaxLeverage } from "@/app/lib/multiply-system/leverage-limits"
import type { MultiplyPageData } from "@/app/lib/data/providers/multiply"
import type { PortfolioMultiplyTabData } from "@/app/lib/data/providers/portfolio"
import { MULTIPLY_TOKEN_LOGOS } from "@/app/lib/multiply-sim"
import { resolveMultiplyTokenLogo } from "@/lib/multiply-token-logo"
import type { MultiplyMarketRow } from "@/app/lib/multiply-sim"
import { MULTIPLY_MARKET_CATALOG } from "./catalog"
import { resolveMultiplyCollateralPriceUsd } from "./collateral-limits"
import { formatMultiplyActivityMarketLabel, formatMultiplyLoopPairLabel } from "./market-labels"
import type { MultiplyTransactionHistoryItem, MultiplyTransactionResult, MultiplyWalletReadSnapshot } from "./contracts"
import { buildMockMultiplyRiskSnapshots } from "./mock"
import { formatPercent } from "@/app/lib/format"

const MS_PER_YEAR = 365 * 24 * 60 * 60 * 1000

function formatFactor(value: number) {
  return `${value.toFixed(2)}x`
}

export type MultiplyTrendingSnapshot = {
  marketId: string
  label: string
  href: string
  maxLeverageLabel: string
  apyLabel: string
  apyPct: number
  availableLabel: string
  availableUsd: number
  collateralSymbol: string
  borrowSymbol: string
  collateralLogo: string
  borrowLogo: string
}

export function buildMultiplyTrendingSnapshots(markets: MultiplyMarketRecord[]): MultiplyTrendingSnapshot[] {
  return [...markets]
    .map((market) => {
      // Single-source the max-leverage figure so the trending card, markets table, hero average
      // and explore table all print the same number, and derive the APY from that multiplier.
      const maxMultiplier = resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier)
      const maxLeverageApy = calculateMaxLeverageApy({
        supplyApy: market.economics.supplyApy,
        borrowApy: market.economics.borrowApy,
        safeMaxMultiplier: maxMultiplier,
      })
      const collateralSymbol = market.collateralAsset.symbol
      const borrowSymbol = market.borrowAsset.symbol

      return {
        maxLeverageApy,
        snapshot: {
          marketId: market.id,
          label: `${collateralSymbol}-${borrowSymbol}`,
          href: `/multiply/markets/${market.id}`,
          maxLeverageLabel: formatFactor(maxMultiplier),
          apyPct: maxLeverageApy * 100,
          apyLabel: formatPercent(maxLeverageApy * 100),
          availableUsd: market.economics.availableLiquidityUsd,
          availableLabel: formatCompactUsd(market.economics.availableLiquidityUsd),
          collateralSymbol,
          borrowSymbol,
          collateralLogo: resolveMultiplyTokenLogo(collateralSymbol),
          borrowLogo: resolveMultiplyTokenLogo(borrowSymbol),
        },
      }
    })
    .filter((entry) => entry.maxLeverageApy > 0)
    .sort((left, right) => right.maxLeverageApy - left.maxLeverageApy)
    .slice(0, 3)
    .map((entry) => entry.snapshot)
}

export function catalogMarketToRow(market: MultiplyMarketRecord): MultiplyMarketRow {
  const collateralSymbol = market.collateralAsset.symbol
  const borrowSymbol = market.borrowAsset.symbol
  const collateralLogo = resolveMultiplyTokenLogo(collateralSymbol)
  const maxLeverage = resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier)
  return {
    href: `/multiply/markets/${market.id}`,
    protocol: collateralSymbol,
    protocolName: market.collateralAsset.name,
    protocolLogo: collateralLogo,
    asset: borrowSymbol,
    assetName: market.borrowAsset.name,
    kind: "Loop",
    apy: formatPercent(market.economics.estimatedMaxApy * 100),
    apyLabel: "Estimated max APY at public max multiplier",
    points: formatCompactUsd(market.economics.availableLiquidityUsd),
    availablePrimary: formatTokenQuantity(
      market.economics.availableLiquidityUsd / market.borrowAsset.priceUsd,
      borrowSymbol,
    ),
    availableSecondary: formatCompactUsd(market.economics.availableLiquidityUsd),
    // The explore table renders the primary reward row under its MAX LEVERAGE
    // header with the single-sourced public max only — no recommended cap here.
    rewardRows: [
      {
        label: `Collateral factor ${Math.round(market.risk.collateralFactor * 100)}% · Liquidation threshold ${Math.round(market.risk.liquidationThreshold * 100)}%`,
        value: formatFactor(maxLeverage),
      },
    ],
    collateralFactor: market.risk.collateralFactor,
    liquidationThreshold: market.risk.liquidationThreshold,
    capacityFilledPct: market.economics.utilizationPct,
  }
}

/**
 * Row shape returned by api.multiply.tokenParameters.listTokens. Declared structurally so this
 * file never imports Convex generated code, which would drag SSR into the Convex runtime.
 */
export type MultiplyTokenParameterRow = {
  symbol: string
  supplyApyPct: number
  borrowAprPct: number
  availableUsd: number
  collateralFactorPct: number
  liquidationThresholdPct: number
  iconUrl: string
}

/** Token-logo map built from Convex rows; symbols line up 1:1 with MULTIPLY_TOKEN_LOGOS keys. */
function buildTokenLogosFromConvex(rows: readonly MultiplyTokenParameterRow[]): Pick<MultiplyPageData, "tokenLogos"> {
  type TokenSymbol = keyof typeof MULTIPLY_TOKEN_LOGOS
  const logos: Partial<Record<TokenSymbol, string>> = {}
  for (const row of rows) {
    // Resolve icons from the local png map, not row.iconUrl: the deployed Convex seed still
    // carries stale `.svg` paths that 404.
    logos[row.symbol as TokenSymbol] = resolveMultiplyTokenLogo(row.symbol)
  }
  return { tokenLogos: logos as MultiplyPageData["tokenLogos"] }
}

export function buildMultiplyPageData(
  _walletId: string,
  state?: MultiplySystemState,
  convexTokens?: readonly MultiplyTokenParameterRow[],
): MultiplyPageData {
  const markets = state ? Object.values(state.markets) : MULTIPLY_MARKET_CATALOG
  const lendRows = [...markets].sort((a, b) => a.rank - b.rank).map(catalogMarketToRow)

  // Aggregate the hero headline over every loop market, anchored to available liquidity (the
  // same per-row figure the markets table lists) so headline and table reconcile.
  const totalLiquidityUsd = markets.reduce((sum, market) => sum + market.economics.availableLiquidityUsd, 0)
  const marketCount = markets.length
  const averageMaxApy =
    marketCount > 0 ? markets.reduce((sum, market) => sum + market.economics.estimatedMaxApy, 0) / marketCount : 0
  const averageMaxLeverage =
    marketCount > 0
      ? markets.reduce(
          (sum, market) => sum + resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier),
          0,
        ) / marketCount
      : 0

  // SSR/test path uses the multiply-sim logo constant; the client hydrator passes
  // convexTokens and the logos come from Convex multiplyTokenParameters (16 rows).
  const tokenMaps = convexTokens ? buildTokenLogosFromConvex(convexTokens) : { tokenLogos: MULTIPLY_TOKEN_LOGOS }

  return {
    markets: [...markets].map((market) => ({
      symbol: market.collateralAsset.symbol,
      name: market.collateralAsset.name,
      price: market.collateralAsset.priceUsd,
      funding: market.economics.borrowApy,
      change: market.economics.estimatedMaxApy * 100,
      volume: market.economics.availableLiquidityUsd,
      maxLeverage: resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier),
      longOi: 62,
      shortOi: 38,
    })),
    heroMetrics: { totalLiquidityUsd, marketCount, averageMaxApy, averageMaxLeverage },
    lendRows,
    trendingSnapshots: buildMultiplyTrendingSnapshots(markets),
    pageSize: 12,
    ...tokenMaps,
  }
}

/**
 * WORST (minimum) active-position HF, never the average: multiply positions are isolated, so an
 * average would hide a near-liquidation position behind a safe one. All-debt-free positions report
 * ∞ (matching the per-row table); only a wallet with no positions reports null.
 */
export function worstMultiplyHealthFactor(healthFactors: readonly number[], positionCount: number): number | null {
  const finite = healthFactors.filter((healthFactor) => Number.isFinite(healthFactor))
  if (finite.length > 0) return Math.min(...finite)
  return positionCount === 0 ? null : Number.POSITIVE_INFINITY
}

/**
 * Flat approximation of the blended liquidation threshold for the multiply credit-line card. Must
 * stay identical to the copy in live-source.ts or the value shifts on hydration.
 */
export const MULTIPLY_LIQUIDATION_THRESHOLD_FACTOR = 0.85

function weightedMultiplyLiquidationThreshold(
  positions: Array<{ marketId: string; collateralValueUsd: number }>,
  markets: MultiplySystemState["markets"],
): number {
  let weighted = 0
  let totalCollateral = 0
  for (const position of positions) {
    const market = markets[position.marketId]
    if (!market) continue
    weighted += position.collateralValueUsd * market.risk.liquidationThreshold
    totalCollateral += position.collateralValueUsd
  }
  if (totalCollateral <= 0) return MULTIPLY_LIQUIDATION_THRESHOLD_FACTOR
  return weighted / totalCollateral
}

export function buildPortfolioMultiplyData(
  walletId: string,
  state: MultiplySystemState,
  history: MultiplyTransactionHistoryItem[] = [],
  /**
   * Live collateral-price resolver. When supplied, collateral is valued at
   * `collateralAmount × livePrice` — the same basis the dashboard headline uses — instead of the
   * USD frozen at open. Omitted keeps the frozen behavior. Debt stays fixed (stablecoin borrow).
   */
  collateralPriceFor?: (symbol: string) => number | undefined,
): PortfolioMultiplyTabData {
  const positions = Object.values(state.positions).filter((position) => position.walletId === walletId)
  const collateralUsdOf = (position: (typeof positions)[number]): number => {
    if (!collateralPriceFor || !(position.collateralAmount > 0)) return position.collateralValueUsd
    const market = state.markets[position.marketId]
    if (!market) return position.collateralValueUsd
    const priceUsd = resolveMultiplyCollateralPriceUsd(
      collateralPriceFor(market.collateralAsset.symbol),
      market.collateralAsset.priceUsd,
    )
    const liveUsd = position.collateralAmount * priceUsd
    return Number.isFinite(liveUsd) && liveUsd > 0 ? liveUsd : position.collateralValueUsd
  }
  // Recompute HF, leverage and LTV from the live-repriced collateral; never read the value frozen
  // at open. Dashboard rule: recompute risk/rate metrics, never read a stored per-position figure.
  const liveHealthFactorOf = (position: (typeof positions)[number]): number => {
    const market = state.markets[position.marketId]
    if (!market) return position.healthFactor === "infinity" ? Number.POSITIVE_INFINITY : position.healthFactor
    const hf = calculateMultiplyHealthFactor(
      collateralUsdOf(position),
      position.debtValueUsd,
      market.risk.liquidationThreshold,
    )
    return hf === "infinity" ? Number.POSITIVE_INFINITY : hf
  }
  const liveMultiplierOf = (position: (typeof positions)[number]): number => {
    const collateralUsd = collateralUsdOf(position)
    const equityUsd = collateralUsd - position.debtValueUsd
    return equityUsd > 0 ? collateralUsd / equityUsd : position.multiplier
  }
  const totalCollateralUsd = positions.reduce((sum, position) => sum + collateralUsdOf(position), 0)
  const totalDebtUsd = positions.reduce((sum, position) => sum + position.debtValueUsd, 0)
  const mappedHealthFactors = positions.map((position) => liveHealthFactorOf(position))
  // Worst-position, not average (see worstMultiplyHealthFactor). Field name kept as
  // averageHealthFactor for now to avoid a repo-wide contract rename.
  const averageHealthFactor = worstMultiplyHealthFactor(mappedHealthFactors, positions.length)

  return {
    creditLines: {
      approvedUsd: totalCollateralUsd,
      liquidationThresholdUsd: totalCollateralUsd * weightedMultiplyLiquidationThreshold(positions, state.markets),
      averageHealthFactor,
      currentLtvPct: totalCollateralUsd > 0 ? (totalDebtUsd / totalCollateralUsd) * 100 : 0,
      totalBorrowedUsd: totalDebtUsd,
      totalCollateralUsd,
    },
    lpCollaterals: positions.map((position) => {
      const market = state.markets[position.marketId]!
      const collateralUsd = collateralUsdOf(position)
      return {
        id: position.id,
        marketId: position.marketId,
        label: formatMultiplyLoopPairLabel(market.collateralAsset.symbol, market.borrowAsset.symbol),
        collateralToken: market.collateralAsset.symbol,
        borrowableToken: market.borrowAsset.symbol,
        // Live leverage off the repriced collateral, consistent with the headline multiplier.
        multiplier: liveMultiplierOf(position),
        protocol: "Avana Multiply",
        // Live health factor off the repriced collateral. A zero-debt position is genuinely
        // infinite; the table renders non-finite health factors as "∞".
        healthFactor: liveHealthFactorOf(position),
        collateralUsd,
        borrowPowerUsd: Math.max(0, collateralUsd - position.debtValueUsd),
        debtUsd: position.debtValueUsd,
        // LTV off the live-repriced collateral so it stays consistent with the value shown.
        ltvPct: collateralUsd > 0 ? (position.debtValueUsd / collateralUsd) * 100 : position.ltv * 100,
        liquidationPriceUsd: position.liquidationPrice,
        netApyPct: position.netApy * 100,
        status: "open" as const,
      }
    }),
    positions: positions.map((position) => {
      const market = state.markets[position.marketId]!
      const collateralUsd = collateralUsdOf(position)
      // PnL = net carry accrued on equity since the position opened. (The previous
      // formula reduced to equity − equity ≡ 0 for every position because
      // collateralValueUsd / multiplier === equity by definition.)
      const equityUsd = Math.max(0, collateralUsd - position.debtValueUsd)
      const elapsedYears = Math.max(0, Date.now() - position.openedAt) / MS_PER_YEAR
      const pnlUsd = equityUsd * position.netApy * elapsedYears
      return {
        id: position.id,
        symbol: market.collateralAsset.symbol,
        label: formatMultiplyLoopPairLabel(market.collateralAsset.symbol, market.borrowAsset.symbol),
        side: "long" as const,
        leverage: liveMultiplierOf(position),
        collateralUsd,
        exposureUsd: collateralUsd,
        pnlUsd,
        pnlPct: equityUsd > 0 ? (pnlUsd / equityUsd) * 100 : 0,
        status: "open" as const,
      }
    }),
    openOrders: [],
    twapOrders: [],
    history: buildMultiplyActivityHistory(walletId, history),
  }
}

/**
 * Canonical Multiply Net APY: equity-weighted mean of each position's netApy, weight
 * = max(0, collateral − debt), so a large loop dominates the headline more than a tiny one and
 * both agree with the server blend (computePortfolioNetApyPct weights multiply legs by net
 * equity). Returns a fraction, not a percent.
 */
export function multiplyNetApyFraction(
  positions: ReadonlyArray<{ collateralValueUsd: number; debtValueUsd: number; netApy: number }>,
): number {
  const weights = positions.map((position) => Math.max(0, position.collateralValueUsd - position.debtValueUsd))
  const totalWeight = weights.reduce((sum, weight) => sum + weight, 0)
  if (totalWeight <= 0) return 0
  return positions.reduce((sum, position, index) => sum + position.netApy * weights[index]!, 0) / totalWeight
}

export function buildMultiplyWalletSnapshot(
  walletId: string,
  state: MultiplySystemState,
  transactionHistory: MultiplyTransactionHistoryItem[],
): MultiplyWalletReadSnapshot {
  const portfolio = buildPortfolioMultiplyData(walletId, state, transactionHistory)
  const walletPositions = Object.values(state.positions).filter((position) => position.walletId === walletId)

  // The aggregate multiplier is the true portfolio leverage (total exposure / total equity);
  // netApy is the equity-weighted mean via the shared multiplyNetApyFraction helper.
  const totalCollateralUsd = portfolio.creditLines.totalCollateralUsd
  const totalEquityUsd = totalCollateralUsd - portfolio.creditLines.totalBorrowedUsd

  return {
    walletId,
    transactionHistory,
    metrics: {
      collateralValueUsd: portfolio.creditLines.totalCollateralUsd,
      debtValueUsd: portfolio.creditLines.totalBorrowedUsd,
      multiplier: totalEquityUsd > 0 ? totalCollateralUsd / totalEquityUsd : 1,
      ltv: portfolio.creditLines.currentLtvPct / 100,
      // Collapse both "no positions" (null) and "positions but all debt-free" (∞)
      // to the canonical "infinity" sentinel this field uses across the system.
      healthFactor: Number.isFinite(portfolio.creditLines.averageHealthFactor)
        ? (portfolio.creditLines.averageHealthFactor as number)
        : "infinity",
      netApy: multiplyNetApyFraction(walletPositions),
    },
    riskSnapshots: buildMockMultiplyRiskSnapshots(state).filter((snapshot) =>
      Object.values(state.positions).some(
        (position) => position.walletId === walletId && position.marketId === snapshot.marketId,
      ),
    ),
  }
}

export function buildSyntheticReceipts(history: MultiplyTransactionHistoryItem[]): MultiplyTransactionResult[] {
  return history.map((item) => ({
    id: item.id,
    hash: item.hash,
    status: item.status,
    actionType: item.kind,
    simulated: item.simulated,
    timestamp: item.timestamp,
  }))
}

/**
 * Leverage each market's open reached, inferred from the largest `multiplierBefore` among later
 * unwinds (leverage peaks at open). Needed for positions that have since CLOSED: their position row
 * is gone, so the position-multiplier fallback would render "1.00x → 1.00x".
 */
export function inferOpenedLeverageByMarket(
  transactions: ReadonlyArray<{
    product?: string
    kind: string
    marketSlug?: string | null
    multiplierBefore?: number
  }>,
): Map<string, number> {
  const byMarket = new Map<string, number>()
  for (const transaction of transactions) {
    if (transaction.product !== undefined && transaction.product !== "multiply") continue
    if (transaction.kind !== "close" && transaction.kind !== "deleverage" && transaction.kind !== "reduce") continue
    const before = transaction.multiplierBefore
    const slug = transaction.marketSlug
    if (typeof before === "number" && before > 1 && slug) {
      byMarket.set(slug, Math.max(byMarket.get(slug) ?? 0, before))
    }
  }
  return byMarket
}

export function buildMultiplyActivityHistory(
  walletId: string,
  history: MultiplyTransactionHistoryItem[],
): PortfolioMultiplyTabData["history"] {
  return history
    .filter((item) => item.walletId === walletId)
    .map((item) => {
      // A deleverage that unwinds all the way to 1.00x is a close, not a "Reduce".
      // Treat it as one so the activity log reads "Close · Position closed".
      const isClose = item.kind === "close" || (item.kind === "deleverage" && item.multiplierAfter <= 1.0001)
      return {
        id: item.id,
        at: new Date(item.timestamp).toISOString(),
        product: "multiply" as const,
        kind: item.kind === "multiply" ? ("open" as const) : isClose ? ("close" as const) : ("reduce" as const),
        status: item.status === "success" ? ("confirmed" as const) : ("failed" as const),
        amountUsd: item.amountUsd,
        primaryLabel: item.kind === "multiply" ? "Multiply" : isClose ? "Close position" : "Deleverage",
        secondaryLabel: isClose
          ? `${formatMultiplyActivityMarketLabel(item.marketId)} · Position closed`
          : `${formatMultiplyActivityMarketLabel(item.marketId)} · ${item.multiplierBefore.toFixed(2)}x → ${item.multiplierAfter.toFixed(2)}x`,
        txHash: item.hash,
        marketId: item.marketId,
      }
    })
}
