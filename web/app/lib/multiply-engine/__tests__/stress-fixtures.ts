import type { MultiplyAction, MultiplySystemState } from "@/app/lib/multiply-engine"
import { makeExampleMultiplySystemState } from "@/app/lib/multiply-engine/__tests__/fixtures"

export function makeStressMultiplySystemState(userCount = 100): MultiplySystemState {
  const base = makeExampleMultiplySystemState()
  const marketIds = Object.keys(base.markets)
  const positions: MultiplySystemState["positions"] = {}

  for (let index = 0; index < userCount; index += 1) {
    const walletId = `wallet-multiply-stress-${index}`
    const marketId = marketIds[index % marketIds.length]!
    const market = base.markets[marketId]!
    const hasPosition = index % 5 !== 0
    if (!hasPosition) continue

    const isWhale = index % 20 === 0
    const collateralAmount = isWhale ? 10 + (index % 5) : 0.5 + (index % 4) * 0.25
    const multiplier = isWhale ? 3.5 : 1.8 + (index % 3) * 0.3
    const collateralValueUsd = collateralAmount * market.collateralAsset.priceUsd
    const totalExposure = collateralValueUsd * multiplier
    const debtValueUsd = totalExposure - collateralValueUsd
    const positionId = `${walletId}:${marketId}`

    positions[positionId] = {
      id: positionId,
      walletId,
      marketId,
      collateralAmount: collateralAmount * multiplier,
      collateralValueUsd: totalExposure,
      debtValueUsd,
      multiplier,
      ltv: debtValueUsd / totalExposure,
      healthFactor: (totalExposure * market.risk.liquidationThreshold) / debtValueUsd,
      liquidationPrice: debtValueUsd / (collateralAmount * multiplier * market.risk.liquidationThreshold),
      netApy: market.economics.estimatedMaxApy,
      openedAt: base.now - index * 60_000,
      lastUpdatedAt: base.now - index * 30_000,
    }
  }

  return {
    ...base,
    positions,
    transactions: [],
  }
}

export function makeStressMultiplyActions(state: MultiplySystemState): MultiplyAction[] {
  const actions: MultiplyAction[] = []
  const marketIds = Object.keys(state.markets)

  for (let index = 0; index < 100; index += 1) {
    const walletId = `wallet-multiply-stress-${index}`
    const marketId = marketIds[index % marketIds.length]!
    const market = state.markets[marketId]!
    const positionId = `${walletId}:${marketId}`
    const existing = state.positions[positionId]
    const baseAt = state.now + index * 1000

    if (!existing) {
      actions.push({
        type: "multiply",
        walletId,
        marketId,
        collateralAmount: 0.25 + (index % 5) * 0.1,
        selectedMultiplier: Math.min(2 + (index % 4) * 0.2, market.risk.publicMaxMultiplier),
        at: baseAt,
      })
      continue
    }

    if (index % 3 === 0) {
      actions.push({
        type: "deleverage",
        walletId,
        positionId,
        targetMultiplier: Math.max(1.2, existing.multiplier - 0.4),
        at: baseAt,
      })
      continue
    }

    actions.push({
      type: "multiply",
      walletId,
      marketId,
      collateralAmount: 0.1 + (index % 3) * 0.05,
      selectedMultiplier: Math.min(existing.multiplier + 0.2, market.risk.publicMaxMultiplier),
      at: baseAt,
    })
  }

  actions.push({
    type: "multiply",
    walletId: "wallet-multiply-stress-99",
    marketId: marketIds[0]!,
    collateralAmount: 1,
    selectedMultiplier: 99,
    at: state.now + 999_999,
  })

  return actions
}
