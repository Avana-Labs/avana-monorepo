import type { LendMarket, LendPosition } from "./types"

export function validateDepositAction(params: {
  depositAmount: number
  walletBalance?: number
  market: LendMarket
  assetSupported: boolean
  priceStale?: boolean
}) {
  const errors: string[] = []
  const warnings: string[] = []

  if (params.depositAmount <= 0) errors.push("Deposit amount must be positive.")
  if (!params.assetSupported) errors.push("Asset is not supported for lending.")
  if (params.market.status === "paused") errors.push("Market is paused.")
  if (params.walletBalance !== undefined && params.depositAmount > params.walletBalance) {
    errors.push("Insufficient wallet balance.")
  }
  if (params.market.assetPriceUsd <= 0) errors.push("Asset price is missing.")
  if (params.priceStale) errors.push("Asset price data is stale.")

  const nextTotalSupplied = params.market.totalSupplied + params.depositAmount
  if (params.market.supplyCap !== undefined && nextTotalSupplied > params.market.supplyCap) {
    errors.push("Deposit would exceed the market supply cap.")
  }

  const totalApy = params.market.supplyApy + params.market.rewardsApy
  if (totalApy < 0.001) warnings.push("Total APY is very low.")
  if (params.market.utilization >= 0.9) warnings.push("Market utilization is very high.")
  if (params.market.supplyCap !== undefined && params.market.totalSupplied / params.market.supplyCap >= 0.9) {
    warnings.push("Market is close to its supply cap.")
  }
  if (params.priceStale) warnings.push("Asset price data is stale.")

  return { allowed: errors.length === 0, errors, warnings }
}

export function validateWithdrawAction(params: {
  withdrawAmount: number
  market: LendMarket
  position?: LendPosition
  currentSuppliedBalance: number
  maxWithdrawable: number
  priceStale?: boolean
}) {
  const errors: string[] = []
  const warnings: string[] = []

  if (params.withdrawAmount <= 0) errors.push("Withdraw amount must be positive.")
  if (!params.position || params.position.status !== "active") errors.push("Position does not exist.")
  if (params.withdrawAmount > params.currentSuppliedBalance) {
    errors.push("Withdraw amount exceeds current supplied balance.")
  }
  if (params.withdrawAmount > params.maxWithdrawable) {
    errors.push("Withdraw amount exceeds available market liquidity.")
  }
  if (params.market.status === "paused") errors.push("Market is paused.")
  if (params.market.assetPriceUsd <= 0) errors.push("Asset price is missing.")
  if (params.priceStale) errors.push("Asset price data is stale.")

  if (Math.abs(params.withdrawAmount - params.currentSuppliedBalance) < 1e-9 && params.currentSuppliedBalance > 0) {
    warnings.push("Withdraw amount equals the full supplied balance.")
  }
  if (params.maxWithdrawable < params.currentSuppliedBalance) {
    warnings.push("Available market liquidity is low.")
  }
  if (params.priceStale) warnings.push("Asset price data is stale.")

  return { allowed: errors.length === 0, errors, warnings }
}
