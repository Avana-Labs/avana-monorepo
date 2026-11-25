import {
  calculateBorrowCapacityUsd6,
  calculateCollateralValueUsd6,
  calculateCreditMetrics,
  calculateCurrentLtvWad,
  calculateHealthFactorWad,
  formatFixed,
  type BorrowSystemState,
} from "@/app/lib/borrow-system/model"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"
import { formatBorrowLpSymbolLabel } from "@/app/lib/borrow-system/market-labels"
import type { TransactionHistoryItem, TransactionMetricsSnapshot, WalletReadSnapshot } from "./contracts"
import {
  selectBorrowCollateralPools,
  selectBorrowMarketSummaries,
  selectBorrowableAssets,
  selectInitialBorrowDebts,
  selectWalletBorrowSnapshot,
} from "./selectors"
import { selectBorrowSnapshot, selectPortfolioDebtRows, selectPortfolioSupplyRows } from "./dashboard-selectors"
import { dexForRow } from "@/app/lib/borrow-market-rows"

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

export function mapTransactionHistoryToActivityRows(
  history: TransactionHistoryItem[],
  markets?: MarketDisplayLookup,
  assets?: Record<string, { symbol: string }>,
) {
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
    const debtAsset = isDebtAction && item.assetId && assets ? assets[item.assetId] : null

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
  transactionHistory: TransactionHistoryItem[] = [],
): WalletReadSnapshot {
  return {
    walletId,
    transactionHistory,
    creditSnapshot: toMetricsSnapshot(state, walletId),
  }
}

export function buildBorrowPageData(state: BorrowSystemState, walletId: string): BorrowPageData {
  const accrued = state
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
    poolCatalog,
    heroMetrics: {
      totalTvlUsd,
      totalCollateralUsd,
      availableCreditUsd,
      outstandingLoansUsd,
      totalTvlChangePct,
    },
    borrowableAssets: selectBorrowableAssets(state, walletId),
    pendingRows: [],
    dexes: [...new Map(poolCatalog.map((row) => [row.dexId, dexForRow(row)])).values()],
    collateralPools: selectBorrowCollateralPools(accrued, walletId),
    initialDebts: selectInitialBorrowDebts(accrued, walletId),
    borrowSnapshot: selectWalletBorrowSnapshot(accrued, walletId),
  }
}

export function buildPortfolioBorrowData(state: BorrowSystemState, walletId: string): PortfolioBorrowTabData {
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
