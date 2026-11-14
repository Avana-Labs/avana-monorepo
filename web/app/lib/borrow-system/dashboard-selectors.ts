import {
  calculateHealthFactorWad,
  calculateSpokeCreditMetrics,
  collateralInterestEarnedUsd6,
  currentDebtValueUsd6,
  formatFixed,
  totalDebtValueUsd6,
  type BorrowSpokeId,
  type BorrowSystemState,
} from "@/app/lib/borrow-system/model"
import type { DebtRowContext, SupplyRowContext } from "@/app/lib/data/borrow-position-types"
import {
  resolveBorrowAprPct,
  selectAllAvailableCollateralPools,
  selectBorrowCollateralPools,
  selectInitialBorrowDebts,
  selectWalletBorrowSnapshot,
} from "@/app/lib/borrow-system/selectors"
import { formatUsdExact } from "@/app/lib/borrow-market-rows"
import type { BorrowSnapshot } from "@/app/dashboard/borrow-hero-state"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

function spokeHealthFactor(state: BorrowSystemState, walletId: string, marketId: string) {
  const spokeId = state.markets[marketId]?.spokeId
  if (!spokeId) return Number.POSITIVE_INFINITY
  const healthFactorWad = calculateHealthFactorWad(state, walletId, spokeId)
  return healthFactorWad != null ? fixedToNumber(healthFactorWad, 18) : Number.POSITIVE_INFINITY
}

export function selectPortfolioSupplyRows(state: BorrowSystemState, walletId: string): SupplyRowContext[] {
  const pools = selectBorrowCollateralPools(state, walletId)
  const debts = selectInitialBorrowDebts(state, walletId)
  const account = state.accounts[walletId]

  return pools.map((pool) => {
    const position = account?.collateralPositions.find((entry) => entry.marketId === pool.id)
    const market = state.markets[pool.id]
    const feesUsd = position && market ? fixedToNumber(collateralInterestEarnedUsd6(position, market), 6) : 0

    // Per-position borrow power: THIS pool's own collateral × its max LTV, minus
    // this pool's own outstanding debt, clamped at zero. Previously this column read
    // the whole-spoke available credit, so every collateral position sharing a spoke
    // reported the SAME number and could exceed a single position's collateral. maxLtv
    // is a percentage (e.g. 75); clamped at 100 so borrow power never exceeds collateral.
    const borrowedUsd = debts[pool.id] ?? 0
    const poolBorrowPowerUsd = pool.collateralUsd * (Math.min(pool.maxLtv, 100) / 100)
    const remainingBorrowPowerUsd = Math.max(0, poolBorrowPowerUsd - borrowedUsd)

    return {
      pool,
      borrowedUsd,
      remainingBorrowPowerUsd,
      liquidationThresholdUsd: pool.liquidationUsd,
      healthFactor: spokeHealthFactor(state, walletId, pool.id),
      pairApr: pool.pairApr,
      feesUsd,
      feesLabel: formatUsdExact(feesUsd),
    }
  })
}

// Health factor for a debt row. Uses the debt position's OWN spoke — which
// provably contains this debt — rather than a matched collateral pool's spoke.
// Falls back to the wallet-wide health factor if the debt has no resolvable
// spoke, so a debt row can never falsely read ∞ ("safe") while the wallet owes.
function debtHealthFactor(
  state: BorrowSystemState,
  walletId: string,
  position: BorrowSystemState["accounts"][string]["debtPositions"][number],
  walletHealthFactor: number | null,
): number | null {
  const spokeId = position.spokeId ?? (position.marketId ? state.markets[position.marketId]?.spokeId : undefined)
  if (spokeId) {
    const healthFactorWad = calculateHealthFactorWad(state, walletId, spokeId)
    if (healthFactorWad != null) return fixedToNumber(healthFactorWad, 18)
  }
  return walletHealthFactor
}

export function selectPortfolioDebtRows(state: BorrowSystemState, walletId: string): DebtRowContext[] {
  const account = state.accounts[walletId]
  if (!account) return []
  // Resolve against the FULL market catalog, not just pledged pools. A debt can
  // exist against a market the wallet has not pledged collateral in (borrowed
  // against spoke-shared collateral); keying on pledged pools only would silently
  // drop that debt from the table while "Total Borrowed" still counts it.
  const poolById = new Map(selectAllAvailableCollateralPools(state, walletId).map((pool) => [pool.id, pool]))
  const walletHealthFactor = selectWalletBorrowSnapshot(state, walletId).healthFactor
  const rows: DebtRowContext[] = []

  for (const position of account.debtPositions) {
    if (currentDebtValueUsd6(position) <= 0n) continue
    const pool = position.marketId ? poolById.get(position.marketId) : undefined
    if (!pool) continue
    const borrowedUsd = fixedToNumber(currentDebtValueUsd6(position), 6)
    // Single-source the borrow APR to the current market rate (base + risk premium) via the
    // shared resolveBorrowAprPct helper — the SAME source the borrow list and action page use —
    // instead of the stored position rate, so the three surfaces can never disagree (C2).
    const asset = state.assets[position.assetId]
    const borrowApr =
      asset != null
        ? resolveBorrowAprPct(
            asset.borrowConfig.baseBorrowAprWad,
            calculateSpokeCreditMetrics(state, walletId, position.spokeId).riskPremiumWad,
          )
        : fixedToNumber(position.borrowRateWad, 18) * 100
    rows.push({
      id: position.id,
      pool,
      debtAssetId: position.assetId,
      debtAssetSymbol: asset?.symbol ?? "",
      borrowedUsd,
      liquidationThresholdUsd: pool.liquidationUsd,
      healthFactor: debtHealthFactor(state, walletId, position, walletHealthFactor),
      borrowApr,
      // Accrue from this debt's own open time at the rate shown in the row, instead of the engine
      // index (which only advances on read and shares one account clock any action resets). Matches
      // the Interest Owed tile's per-position basis and the Lend/Multiply counters.
      accruedInterestUsd:
        (borrowedUsd * (borrowApr / 100) * Math.max(0, Date.now() - (position.openedAt ?? Date.now()))) /
        (365 * 24 * 60 * 60 * 1000),
      dailyInterestUsd: (borrowedUsd * (borrowApr / 100)) / 365,
    })
  }

  return rows
}

export function selectBorrowSnapshot(state: BorrowSystemState, walletId: string): BorrowSnapshot {
  const account = state.accounts[walletId]
  if (!account) {
    return {
      approvedUsd: 0,
      liquidationThresholdUsd: 0,
      totalBorrowedUsd: 0,
      totalCollateralUsd: 0,
      averageHealthFactor: null,
      currentLtvPct: 0,
      spokeBreakdown: [],
    }
  }

  const walletSnapshot = selectWalletBorrowSnapshot(state, walletId)
  const totalCollateralUsd = walletSnapshot.totalCollateralUsd
  const totalBorrowedUsd = fixedToNumber(totalDebtValueUsd6(account), 6)
  const ownedSpokes = Array.from(
    new Set(account.collateralPositions.map((position) => state.markets[position.marketId]?.spokeId).filter(Boolean)),
  ) as BorrowSpokeId[]
  const spokeBreakdown = ownedSpokes
    .map((spokeId) => {
      const metrics = calculateSpokeCreditMetrics(state, walletId, spokeId)
      const label = Object.values(state.markets).find((market) => market.spokeId === spokeId)?.display.venue ?? spokeId

      return {
        spokeId,
        label,
        availableCreditUsd: fixedToNumber(metrics.availableCreditUsd6, 6),
        totalBorrowedUsd: fixedToNumber(metrics.totalBorrowedUsd6, 6),
        liquidationBufferUsd: fixedToNumber(metrics.liquidationBufferUsd6 > 0n ? metrics.liquidationBufferUsd6 : 0n, 6),
        healthFactor: metrics.totalBorrowedUsd6 > 0n ? fixedToNumber(metrics.healthFactorWad, 18) : null,
      }
    })
    .sort((left, right) => right.totalBorrowedUsd - left.totalBorrowedUsd)

  return {
    approvedUsd: walletSnapshot.availableCreditUsd,
    liquidationThresholdUsd: walletSnapshot.liquidationValueUsd,
    totalBorrowedUsd,
    totalCollateralUsd,
    averageHealthFactor: walletSnapshot.healthFactor,
    currentLtvPct: totalCollateralUsd > 0 ? (totalBorrowedUsd / totalCollateralUsd) * 100 : 0,
    spokeBreakdown,
  }
}
