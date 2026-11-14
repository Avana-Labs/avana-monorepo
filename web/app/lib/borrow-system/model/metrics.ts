import type { BorrowAccountState, BorrowSpokeId, BorrowSystemState } from "./types"
import { WAD, mulDiv, parseFixed } from "./units"
import {
  calculateCollateralValueUsd6,
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  totalCollateralValueUsd6,
  totalDebtValueUsd6,
  totalInterestEarnedUsd6,
  totalInterestOwedUsd6,
} from "./valuation"

const COLLATERAL_RISK_MULTIPLIER_WAD = parseFixed("0.04", 18)
const UTILIZATION_PREMIUM_MULTIPLIER_WAD = parseFixed("0.03", 18)
const LOW_HEALTH_TRIGGER_WAD = parseFixed("1.5", 18)
const LOW_HEALTH_MULTIPLIER_WAD = parseFixed("0.05", 18)
// Net APY = annual carry / net equity, so a near-zero equity denominator explodes.
// ±1000% is above any legitimate net APY here, so real values are never clipped.
export const MAX_NET_APY_MAGNITUDE_WAD = parseFixed("10", 18)

/** Bound net APY to ±1000% so a near-zero-equity denominator can't produce an absurd headline. */
export function clampNetApyWad(rawWad: bigint): bigint {
  if (rawWad > MAX_NET_APY_MAGNITUDE_WAD) return MAX_NET_APY_MAGNITUDE_WAD
  if (rawWad < -MAX_NET_APY_MAGNITUDE_WAD) return -MAX_NET_APY_MAGNITUDE_WAD
  return rawWad
}

type BorrowCreditMetrics = {
  netAccountValueUsd6: bigint
  poolCollateralValueUsd6: bigint
  creditLimitUsd6: bigint
  availableCreditUsd6: bigint
  totalBorrowedUsd6: bigint
  liquidationValueUsd6: bigint
  liquidationBufferUsd6: bigint
  liquidationBufferPercentWad: bigint
  healthFactorWad: bigint
  baseBorrowAprWad: bigint
  borrowAprWad: bigint
  riskPremiumWad: bigint
  weightedCollateralRiskWad: bigint
  utilizationWad: bigint
  collateralRiskPremiumWad: bigint
  utilizationPremiumWad: bigint
  lowHealthPremiumWad: bigint
  netApyWad: bigint
  annualYieldEarnedUsd6: bigint
  annualBorrowCostUsd6: bigint
  interestEarnedUsd6: bigint
  interestOwedUsd6: bigint
}

function weightedBaseBorrowAprWad(account: BorrowAccountState, state: BorrowSystemState, totalBorrowedUsd6: bigint) {
  if (totalBorrowedUsd6 === 0n) return 0n
  const numerator = account.debtPositions.reduce((sum, position) => {
    const asset = state.assets[position.assetId]
    if (!asset) return sum
    return sum + currentDebtValueUsd6(position) * asset.borrowConfig.baseBorrowAprWad
  }, 0n)
  return numerator / totalBorrowedUsd6
}

function scopeAccountBySpoke(
  state: BorrowSystemState,
  account: BorrowAccountState,
  spokeId?: BorrowSpokeId,
): BorrowAccountState {
  if (!spokeId) return account

  return {
    ...account,
    collateralPositions: account.collateralPositions.filter(
      (position) => state.markets[position.marketId]?.spokeId === spokeId,
    ),
    debtPositions: account.debtPositions.filter((position) => position.spokeId === spokeId),
  }
}

function calculateMetricsForAccount(state: BorrowSystemState, account: BorrowAccountState): BorrowCreditMetrics {
  const poolCollateralValueUsd6 = totalCollateralValueUsd6(account, state.markets)
  // Reprices debt to each borrowed asset's spot price, so a depegged debt moves the health factor.
  const totalBorrowedUsd6 = totalDebtValueUsd6(account, state.assets)
  const interestEarnedUsd6 = totalInterestEarnedUsd6(account, state.markets)
  const interestOwedUsd6 = totalInterestOwedUsd6(account)

  let creditLimitUsd6 = 0n
  let liquidationValueUsd6 = 0n
  let weightedRiskNumerator = 0n
  let annualYieldEarnedUsd6 = 0n

  for (const position of account.collateralPositions) {
    if (!position.collateralEnabled) continue
    const market = state.markets[position.marketId]
    if (!market) continue
    const valueUsd6 = currentCollateralValueUsd6(position, market)
    // Borrow capacity uses the collateral factor (max LTV), never the (strictly higher)
    // liquidation threshold — that one only sizes the liquidation value / health factor.
    creditLimitUsd6 += mulDiv(valueUsd6, market.riskConfig.collateralFactorWad, WAD)
    liquidationValueUsd6 += mulDiv(valueUsd6, market.riskConfig.liquidationThresholdWad, WAD)
    weightedRiskNumerator += valueUsd6 * market.riskConfig.riskScoreWad
    annualYieldEarnedUsd6 += mulDiv(valueUsd6, market.snapshot.feeApyWad, WAD)
  }

  const availableCreditUsd6 = creditLimitUsd6 > totalBorrowedUsd6 ? creditLimitUsd6 - totalBorrowedUsd6 : 0n
  const netAccountValueUsd6 =
    poolCollateralValueUsd6 + account.walletBalanceUsd6 - totalBorrowedUsd6 + account.interestSettledUsd6

  const healthFactorWad = totalBorrowedUsd6 > 0n ? mulDiv(liquidationValueUsd6, WAD, totalBorrowedUsd6) : 0n
  const liquidationBufferUsd6 = liquidationValueUsd6 - totalBorrowedUsd6
  const liquidationBufferPercentWad =
    liquidationValueUsd6 > 0n
      ? mulDiv(liquidationBufferUsd6 > 0n ? liquidationBufferUsd6 : 0n, WAD, liquidationValueUsd6)
      : 0n
  const weightedCollateralRiskWad = poolCollateralValueUsd6 > 0n ? weightedRiskNumerator / poolCollateralValueUsd6 : 0n
  const utilizationWad = creditLimitUsd6 > 0n ? mulDiv(totalBorrowedUsd6, WAD, creditLimitUsd6) : 0n
  const collateralRiskPremiumWad = mulDiv(weightedCollateralRiskWad, COLLATERAL_RISK_MULTIPLIER_WAD, WAD)
  const utilizationPremiumWad = mulDiv(utilizationWad, UTILIZATION_PREMIUM_MULTIPLIER_WAD, WAD)
  const lowHealthPremiumWad =
    totalBorrowedUsd6 > 0n && healthFactorWad < LOW_HEALTH_TRIGGER_WAD
      ? mulDiv(LOW_HEALTH_TRIGGER_WAD - healthFactorWad, LOW_HEALTH_MULTIPLIER_WAD, WAD)
      : 0n
  const riskPremiumWad = collateralRiskPremiumWad + utilizationPremiumWad + lowHealthPremiumWad
  const baseBorrowAprWad = weightedBaseBorrowAprWad(account, state, totalBorrowedUsd6)
  const borrowAprWad = baseBorrowAprWad + riskPremiumWad
  const annualBorrowCostUsd6 = mulDiv(totalBorrowedUsd6, borrowAprWad, WAD)
  const rawNetApyWad =
    netAccountValueUsd6 > 0n ? mulDiv(annualYieldEarnedUsd6 - annualBorrowCostUsd6, WAD, netAccountValueUsd6) : 0n
  const netApyWad = clampNetApyWad(rawNetApyWad)

  return {
    netAccountValueUsd6,
    poolCollateralValueUsd6,
    creditLimitUsd6,
    availableCreditUsd6,
    totalBorrowedUsd6,
    liquidationValueUsd6,
    liquidationBufferUsd6,
    liquidationBufferPercentWad,
    healthFactorWad,
    baseBorrowAprWad,
    borrowAprWad,
    riskPremiumWad,
    weightedCollateralRiskWad,
    utilizationWad,
    collateralRiskPremiumWad,
    utilizationPremiumWad,
    lowHealthPremiumWad,
    netApyWad,
    annualYieldEarnedUsd6,
    annualBorrowCostUsd6,
    interestEarnedUsd6,
    interestOwedUsd6,
  }
}

export function calculateCreditMetrics(state: BorrowSystemState, walletId: string): BorrowCreditMetrics {
  const account = state.accounts[walletId]
  if (!account) throw new Error(`Unknown wallet ${walletId}`)
  return calculateMetricsForAccount(state, account)
}

export function calculateSpokeCreditMetrics(
  state: BorrowSystemState,
  walletId: string,
  spokeId: BorrowSpokeId,
): BorrowCreditMetrics {
  const account = state.accounts[walletId]
  if (!account) throw new Error(`Unknown wallet ${walletId}`)
  return calculateMetricsForAccount(state, scopeAccountBySpoke(state, account, spokeId))
}

export function calculateBorrowCapacityUsd6(state: BorrowSystemState, walletId: string, spokeId?: BorrowSpokeId) {
  const metrics = spokeId
    ? calculateSpokeCreditMetrics(state, walletId, spokeId)
    : calculateCreditMetrics(state, walletId)
  const collateralValueUsd6 = spokeId
    ? totalCollateralValueUsd6(scopeAccountBySpoke(state, state.accounts[walletId]!, spokeId), state.markets)
    : calculateCollateralValueUsd6(state, walletId)
  return metrics.creditLimitUsd6 > collateralValueUsd6 ? collateralValueUsd6 : metrics.creditLimitUsd6
}

export function calculateCurrentLtvWad(state: BorrowSystemState, walletId: string, spokeId?: BorrowSpokeId) {
  const metrics = spokeId
    ? calculateSpokeCreditMetrics(state, walletId, spokeId)
    : calculateCreditMetrics(state, walletId)
  if (metrics.poolCollateralValueUsd6 <= 0n || metrics.totalBorrowedUsd6 <= 0n) return 0n
  return mulDiv(metrics.totalBorrowedUsd6, WAD, metrics.poolCollateralValueUsd6)
}

export function calculateHealthFactorWad(state: BorrowSystemState, walletId: string, spokeId?: BorrowSpokeId) {
  const metrics = spokeId
    ? calculateSpokeCreditMetrics(state, walletId, spokeId)
    : calculateCreditMetrics(state, walletId)
  return metrics.totalBorrowedUsd6 > 0n ? metrics.healthFactorWad : null
}
