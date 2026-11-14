import type { MultiplyPosition, MultiplySystemState } from "./types"

function assertNonNegative(label: string, value: number) {
  if (value < 0) throw new Error(`${label} cannot be negative`)
}

function assertFinite(label: string, value: number) {
  if (!Number.isFinite(value)) throw new Error(`${label} must be finite`)
}

function assertPosition(position: MultiplyPosition, state: MultiplySystemState) {
  if (!state.markets[position.marketId]) {
    throw new Error(`Position ${position.id} references unknown market ${position.marketId}`)
  }
  assertNonNegative(`${position.id}.collateralAmount`, position.collateralAmount)
  assertNonNegative(`${position.id}.collateralValueUsd`, position.collateralValueUsd)
  assertNonNegative(`${position.id}.debtValueUsd`, position.debtValueUsd)
  assertFinite(`${position.id}.multiplier`, position.multiplier)
  assertFinite(`${position.id}.ltv`, position.ltv)
  if (position.multiplier < 1) throw new Error(`Position ${position.id} multiplier must be >= 1`)
}

export function assertMultiplySystemInvariants(state: MultiplySystemState) {
  for (const market of Object.values(state.markets)) {
    assertFinite(`${market.id}.maxLtv`, market.risk.maxLtv)
    assertFinite(`${market.id}.liquidationThreshold`, market.risk.liquidationThreshold)
    assertNonNegative(`${market.id}.availableLiquidityUsd`, market.economics.availableLiquidityUsd)
  }

  const positionIds = new Set<string>()
  for (const position of Object.values(state.positions)) {
    if (positionIds.has(position.id)) throw new Error(`Duplicate position id: ${position.id}`)
    positionIds.add(position.id)
    assertPosition(position, state)
  }

  for (const transaction of state.transactions) {
    assertFinite(`${transaction.id}.collateralAmountUsd`, transaction.collateralAmountUsd)
    assertFinite(`${transaction.id}.multiplierBefore`, transaction.multiplierBefore)
    assertFinite(`${transaction.id}.multiplierAfter`, transaction.multiplierAfter)
    if (!state.markets[transaction.marketId]) {
      throw new Error(`Transaction ${transaction.id} references unknown market ${transaction.marketId}`)
    }
  }
}
