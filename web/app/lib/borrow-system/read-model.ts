import {
  accrueBorrowSystemState,
  calculateBorrowCapacityUsd6,
  calculateCollateralValueUsd6,
  calculateCreditMetrics,
  calculateCurrentLtvWad,
  calculateHealthFactorWad,
  formatFixed,
  type BorrowSystemState,
} from "@/app/lib/credit-engine"
import { buildAssetDetail, resolveAsset } from "@/app/lib/borrow-detail/asset.mock"
import { buildPoolDetail } from "@/app/lib/borrow-detail/pool.mock"
import type { AssetDetail, PoolDetail } from "@/app/lib/borrow-detail/types"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"
import { formatBorrowLpSymbolLabel } from "@/app/lib/borrow-system/market-labels"
import { HOME_POOL_TO_MARKET_ID } from "@/app/lib/borrow-system/mock"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import type { TransactionHistoryItem, TransactionMetricsSnapshot, WalletReadSnapshot } from "./contracts"
import {
  selectBorrowCollateralPools,
  selectBorrowMarketSummaries,
  selectBorrowableAssets,
  selectInitialBorrowDebts,
  selectWalletBorrowSnapshot,
} from "./selectors"
import { selectBorrowSnapshot, selectPortfolioDebtRows, selectPortfolioSupplyRows } from "./dashboard-selectors"
import { BORROW_DEXES, BORROW_PENDING_ROWS } from "@/app/lib/data/catalog/borrow"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

function toMetricsSnapshot(state: BorrowSystemState, walletId: string): TransactionMetricsSnapshot {
  const metrics = calculateCreditMetrics(state, walletId)

  return {
    collateralValueUsd6: calculateCollateralValueUsd6(state, walletId),
    borrowCapacityUsd6: calculateBorrowCapacityUsd6(state, walletId),
    availableBorrowCapacityUsd6: metrics.availableCreditUsd6,
    totalBorrowedUsd6: metrics.totalBorrowedUsd6,
    currentLtvWad: calculateCurrentLtvWad(state, walletId),
    healthFactorWad: calculateHealthFactorWad(state, walletId),
  }
}

export function buildLegacyTransactionHistory(state: BorrowSystemState, walletId: string): TransactionHistoryItem[] {
  return state.transactions
    .filter((transaction) => transaction.walletId === walletId)
    .map((transaction) => ({
      id: transaction.id,
      intentId: `legacy-${transaction.id}`,
      walletId: transaction.walletId,
      marketId: transaction.marketId,
      assetId: transaction.assetId,
      kind: transaction.kind,
      status: "success",
      requestedAmountUsd6: transaction.amountUsd6,
      executedAmountUsd6: transaction.amountUsd6,
      simulated: true,
      timestamp: transaction.at,
      hash: `sim_${transaction.id}`,
    }))
}

export function buildSyntheticReceipts(history: TransactionHistoryItem[]) {
  return history.map((item) => ({
    id: item.id,
    hash: item.hash,
    status: item.status,
    actionType: item.kind,
    simulated: item.simulated,
    timestamp: item.timestamp,
  }))
}

function historyKindToActivityKind(kind: TransactionHistoryItem["kind"]) {
  switch (kind) {
    case "deposit":
      return "pledge" as const
    case "withdraw":
      return "withdraw" as const
    case "borrow":
      return "borrow" as const
    case "repay":
      return "repay" as const
    case "claim":
      return "claim" as const
    case "liquidate":
      return "liquidation" as const
  }
}

const BORROW_KIND_LABEL: Record<TransactionHistoryItem["kind"], string> = {
  borrow: "Borrow",
  repay: "Repay",
  deposit: "Pledge",
  withdraw: "Withdraw",
  claim: "Claim",
  liquidate: "Liquidation",
}

type MarketDisplayLookup = Record<string, { display?: { visuals?: Array<{ symbol: string }>; name?: string } }>

export function mapTransactionHistoryToActivityRows(history: TransactionHistoryItem[], markets?: MarketDisplayLookup) {
  return history.map((item) => {
    const amountUsd = Number.parseFloat(formatFixed(item.executedAmountUsd6, 6))
    const signedAmount =
      item.kind === "borrow" || item.kind === "withdraw" || item.kind === "liquidate"
        ? -Math.abs(amountUsd)
        : Math.abs(amountUsd)

    // Debt actions label by the BORROWED asset; collateral actions by the pool. Same split the
    // detail transaction tables use — labelling every row with the pool mislabels borrows.
    const isDebtAction = item.kind === "borrow" || item.kind === "repay"
    const market = item.marketId && markets ? markets[item.marketId] : undefined
    const poolLabel = market ? formatBorrowLpSymbolLabel(market) : undefined
    const debtAsset = isDebtAction && item.assetId ? resolveAsset(item.assetId) : null

    const fallbackLabel = BORROW_KIND_LABEL[item.kind] ?? "Borrow"
    const primaryLabel = isDebtAction
      ? (debtAsset?.symbol ?? item.assetId?.toUpperCase() ?? fallbackLabel)
      : (poolLabel ?? fallbackLabel)

    // Surface the collateral pool as context on debt rows ("… · via sDAI / USDC").
    const secondaryLabel = isDebtAction && poolLabel ? `via ${poolLabel}` : ""

    return {
      id: item.id,
      at: new Date(item.timestamp).toISOString(),
      product: "borrow" as const,
      kind: historyKindToActivityKind(item.kind),
      status:
        item.status === "success"
          ? ("confirmed" as const)
          : item.status === "failed"
            ? ("failed" as const)
            : ("pending" as const),
      amountUsd: signedAmount,
      primaryLabel,
      secondaryLabel,
      // Icon source: the borrowed asset for debt actions, the collateral pool otherwise.
      marketId: isDebtAction ? (item.assetId ?? undefined) : (item.marketId ?? undefined),
      txHash: item.hash,
    }
  })
}

export function buildWalletReadSnapshot(
  state: BorrowSystemState,
  walletId: string,
  transactionHistory: TransactionHistoryItem[] = buildLegacyTransactionHistory(state, walletId),
  now: number = Date.now(),
): WalletReadSnapshot {
  // Advance indexes to `now` so the displayed HF drifts with interest between actions.
  // accrueBorrowSystemState is immutable and no-ops when now <= state.now.
  const accrued = accrueBorrowSystemState(state, now)
  return {
    walletId,
    transactionHistory,
    creditSnapshot: toMetricsSnapshot(accrued, walletId),
  }
}

export function buildBorrowPageData(
  state: BorrowSystemState,
  walletId: string,
  now: number = Date.now(),
): BorrowPageData {
  // Market-reference figures and the serialized seed read the RAW state (accruing would drift
  // them and bake an advanced `now` into the seed); wallet position views read the accrued copy
  // so detail and dashboard agree.
  const accrued = accrueBorrowSystemState(state, now)
  const poolCatalog = selectBorrowMarketSummaries(state, walletId)
  const markets = Object.values(state.markets)
  const assets = Object.values(state.assets)

  // Same contract as aggregateBorrowEconomyFromSnapshots — the borrow landing hero.
  const totalTvlUsd = markets.reduce((sum, market) => sum + fixedToNumber(market.snapshot.totalLiquidityUsd6, 6), 0)
  const totalCollateralUsd = totalTvlUsd
  const availableCreditUsd = markets.reduce((sum, market) => sum + fixedToNumber(market.snapshot.availableUsd6, 6), 0)
  const outstandingLoansUsd = assets.reduce((sum, asset) => sum + fixedToNumber(asset.snapshot.totalBorrowedUsd6, 6), 0)
  const totalTvlChangePct =
    totalTvlUsd > 0
      ? poolCatalog.reduce((sum, pool) => sum + (pool.change24hPct ?? 0) * pool.tvlUsd, 0) / totalTvlUsd
      : 0

  return {
    walletId,
    // Deliberately empty: the session seed lives in AvanaSessionsProvider (client). Serializing
    // it here added ~250KB to every catalog RSC payload with no consumer on the list page.
    borrowSessionSeed: "",
    poolCatalog,
    heroMetrics: {
      totalTvlUsd,
      totalCollateralUsd,
      availableCreditUsd,
      outstandingLoansUsd,
      totalTvlChangePct,
    },
    borrowableAssets: selectBorrowableAssets(state, walletId),
    pendingRows: BORROW_PENDING_ROWS,
    dexes: BORROW_DEXES,
    collateralPools: selectBorrowCollateralPools(accrued, walletId),
    initialDebts: selectInitialBorrowDebts(accrued, walletId),
    borrowSnapshot: selectWalletBorrowSnapshot(accrued, walletId),
  }
}

export function buildPortfolioBorrowData(
  state: BorrowSystemState,
  walletId: string,
  now: number = Date.now(),
): PortfolioBorrowTabData {
  // Accrue once here so the portfolio HF/debt rows drift with interest between actions;
  // the low-level selectors below stay pure and select from this accrued copy.
  state = accrueBorrowSystemState(state, now)
  const snapshot = selectBorrowSnapshot(state, walletId)
  const debtPositions = selectPortfolioDebtRows(state, walletId).map((position, index) => ({
    ...position,
    id: position.id ?? `${position.pool.id}:debt:${index}`,
  }))

  return {
    creditLines: {
      approvedUsd: snapshot.approvedUsd,
      liquidationThresholdUsd: snapshot.liquidationThresholdUsd,
      averageHealthFactor: snapshot.averageHealthFactor,
      currentLtvPct: snapshot.currentLtvPct,
      totalBorrowedUsd: snapshot.totalBorrowedUsd,
      totalCollateralUsd: snapshot.totalCollateralUsd,
    },
    collateralPositions: selectPortfolioSupplyRows(state, walletId),
    debtPositions,
  }
}

export function resolvePoolDetailFromState(
  state: BorrowSystemState,
  walletId: string,
  poolId: string,
): PoolDetail | null {
  const resolvedId = HOME_POOL_TO_MARKET_ID[poolId] ?? poolId
  const row = selectBorrowMarketSummaries(state, walletId).find((candidate) => candidate.id === resolvedId)
  if (!row) return null
  return buildPoolDetail(row)
}

/** Convex market reference overrides applied to a borrowable asset before building its detail. */
type AssetLiquidityOverrides = {
  availableUsd?: number
  totalBorrowedUsd?: number
  utilization?: number
  borrowApr?: number
}

export function resolveAssetDetailFromState(assetId: string, overrides?: AssetLiquidityOverrides): AssetDetail | null {
  const base = listSpokeBorrowables().find((candidate) => candidate.id === assetId) ?? resolveAsset(assetId)
  if (!base) return null
  const asset = overrides
    ? {
        ...base,
        availableUsd: overrides.availableUsd ?? base.availableUsd,
        totalBorrowedUsd: overrides.totalBorrowedUsd ?? base.totalBorrowedUsd,
        utilization: overrides.utilization ?? base.utilization,
        borrowApr: overrides.borrowApr ?? base.borrowApr,
      }
    : base
  return buildAssetDetail(asset)
}
