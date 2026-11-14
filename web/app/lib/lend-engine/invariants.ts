import type { LendSystemState } from "./types"

function assertNonNegative(label: string, value: number) {
  if (value < 0) throw new Error(`${label} cannot be negative`)
}

export function assertLendSystemInvariants(state: LendSystemState) {
  for (const market of Object.values(state.markets)) {
    assertNonNegative(`${market.marketId}.totalSupplied`, market.totalSupplied)
    assertNonNegative(`${market.marketId}.availableLiquidity`, market.availableLiquidity)
    if (market.utilization < 0 || market.utilization > 1) {
      throw new Error(`${market.marketId}.utilization out of range`)
    }
  }

  for (const position of Object.values(state.positions)) {
    assertNonNegative(`${position.positionId}.currentSuppliedAmount`, position.currentSuppliedAmount)
    assertNonNegative(`${position.positionId}.principalAmount`, position.principalAmount)
    assertNonNegative(`${position.positionId}.interestEarned`, position.interestEarned)
    assertNonNegative(`${position.positionId}.rewardsEarnedUsd`, position.rewardsEarnedUsd)
  }

  for (const [walletId, balances] of Object.entries(state.walletBalances)) {
    for (const [marketId, balance] of Object.entries(balances)) {
      assertNonNegative(`${walletId}.${marketId}.walletBalance`, balance)
    }
  }
}
