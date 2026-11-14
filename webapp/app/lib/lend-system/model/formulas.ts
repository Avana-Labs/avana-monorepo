import { INITIAL_LIQUIDITY_INDEX, MILLISECONDS_PER_SECOND, SECONDS_PER_YEAR } from "./constants"

export function calculateUtilization(totalBorrowed: number, totalSupplied: number): number {
  if (totalSupplied <= 0) return 0
  return totalBorrowed / totalSupplied
}

export function calculateAvailableLiquidity(totalSupplied: number, totalBorrowed: number): number {
  return Math.max(0, totalSupplied - totalBorrowed)
}

export function calculateTotalApy(supplyApy: number, rewardsApy: number): number {
  return supplyApy + rewardsApy
}

export function calculateSuppliedValueUsd(suppliedAmount: number, assetPriceUsd: number): number {
  return suppliedAmount * assetPriceUsd
}

export function calculateElapsedYears(currentTimestamp: number, lastAccrualTimestamp: number): number {
  const elapsedSeconds = Math.max(0, currentTimestamp - lastAccrualTimestamp)
  return elapsedSeconds / (SECONDS_PER_YEAR * MILLISECONDS_PER_SECOND)
}

export function accrueLiquidityIndex(params: {
  oldLiquidityIndex: number
  supplyApy: number
  elapsedYears: number
  compounding?: boolean
}): number {
  if (params.elapsedYears <= 0) return params.oldLiquidityIndex
  if (params.compounding) {
    return params.oldLiquidityIndex * Math.exp(params.supplyApy * params.elapsedYears)
  }
  return params.oldLiquidityIndex * (1 + params.supplyApy * params.elapsedYears)
}

export function calculateScaledDepositAmount(depositAmount: number, liquidityIndex: number): number {
  if (liquidityIndex <= 0) return 0
  return depositAmount / liquidityIndex
}

export function calculateCurrentSuppliedBalance(scaledBalance: number, liquidityIndex: number): number {
  return scaledBalance * liquidityIndex
}

export function calculateInterestEarned(currentSuppliedBalance: number, principalDeposited: number): number {
  return Math.max(0, currentSuppliedBalance - principalDeposited)
}

export function calculateMaxWithdrawable(currentSuppliedBalance: number, availableLiquidity: number): number {
  return Math.min(currentSuppliedBalance, availableLiquidity)
}

export function calculateSimpleInterestAccrued(
  principalAmount: number,
  totalApy: number,
  elapsedYears: number,
): number {
  return principalAmount * totalApy * elapsedYears
}

export function calculateRewardYieldAccruedUsd(params: {
  suppliedAmount: number
  assetPriceUsd: number
  rewardsApy: number
  elapsedYears: number
  existingRewardsEarnedUsd?: number
}) {
  if (params.elapsedYears <= 0 || params.rewardsApy <= 0) {
    return params.existingRewardsEarnedUsd ?? 0
  }

  return (
    (params.existingRewardsEarnedUsd ?? 0) +
    params.suppliedAmount * params.assetPriceUsd * params.rewardsApy * params.elapsedYears
  )
}

export function calculateWithdrawSplit(params: {
  withdrawAmount: number
  currentBalance: number
  principalDeposited: number
}) {
  const interestEarnedTotal = Math.max(0, params.currentBalance - params.principalDeposited)
  if (params.currentBalance <= 0 || params.withdrawAmount <= 0) {
    return { principalWithdrawn: 0, interestWithdrawn: 0, remainingPrincipal: params.principalDeposited }
  }
  const interestRatio = interestEarnedTotal / params.currentBalance
  const interestWithdrawn = params.withdrawAmount * interestRatio
  const principalWithdrawn = params.withdrawAmount - interestWithdrawn
  return {
    principalWithdrawn,
    interestWithdrawn,
    remainingPrincipal: Math.max(0, params.principalDeposited - principalWithdrawn),
  }
}

export function resolveLiquidityIndex(liquidityIndex = INITIAL_LIQUIDITY_INDEX): number {
  return liquidityIndex > 0 ? liquidityIndex : INITIAL_LIQUIDITY_INDEX
}
