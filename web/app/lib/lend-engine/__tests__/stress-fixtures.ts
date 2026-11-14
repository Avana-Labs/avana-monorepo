import type { LendAction, LendSystemState } from "@/app/lib/lend-engine"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"

export function makeStressLendSystemState(userCount = 100): LendSystemState {
  const base = buildMockLendSystemState("wallet-lend-stress-0")
  const marketIds = Object.keys(base.markets)
  const positions: LendSystemState["positions"] = {}

  for (let index = 0; index < userCount; index += 1) {
    const walletId = `wallet-lend-stress-${index}`
    const marketId = marketIds[index % marketIds.length]!
    const market = base.markets[marketId]!
    const hasPosition = index % 4 !== 0
    if (!hasPosition) continue

    const isWhale = index % 20 === 0
    const principalAmount = isWhale ? 500 + (index % 10) : 25 + (index % 8) * 5
    const positionId = `${walletId}:${marketId}`

    positions[positionId] = {
      positionId,
      walletId,
      marketId,
      asset: market.asset.symbol,
      principalAmount,
      scaledBalance: principalAmount,
      liquidityIndexAtLastAction: market.liquidityIndex,
      currentSuppliedAmount: principalAmount,
      interestEarned: principalAmount * 0.01,
      rewardsEarnedUsd: principalAmount * market.assetPriceUsd * 0.002,
      suppliedValueUsd: principalAmount * market.assetPriceUsd,
      openedAt: base.now - index * 60_000,
      updatedAt: base.now - index * 30_000,
      status: "active",
    }
  }

  return {
    ...base,
    positions,
    walletBalances: {
      ...base.walletBalances,
      ...Object.fromEntries(
        Array.from({ length: userCount }, (_, index) => {
          const walletId = `wallet-lend-stress-${index}`
          return [walletId, Object.fromEntries(Object.keys(base.markets).map((marketId) => [marketId, 10_000]))]
        }),
      ),
    },
    transactions: [],
  }
}

export function makeStressLendActions(state: LendSystemState): LendAction[] {
  const actions: LendAction[] = []
  const marketIds = Object.keys(state.markets)

  for (let index = 0; index < 100; index += 1) {
    const walletId = `wallet-lend-stress-${index}`
    const marketId = marketIds[index % marketIds.length]!
    const positionId = `${walletId}:${marketId}`
    const existing = state.positions[positionId]
    const baseAt = state.now + index * 1000

    if (!existing) {
      actions.push({
        type: "deposit",
        walletId,
        marketId,
        depositAmount: 10 + (index % 6) * 5,
        walletBalance: 10_000,
        at: baseAt,
      })
      continue
    }

    if (index % 3 === 0) {
      actions.push({
        type: "withdraw",
        walletId,
        marketId,
        positionId,
        withdrawAmount: Math.min(existing.currentSuppliedAmount * 0.25, existing.currentSuppliedAmount),
        at: baseAt,
      })
      continue
    }

    actions.push({
      type: "deposit",
      walletId,
      marketId,
      depositAmount: 5 + (index % 4) * 2,
      walletBalance: 10_000,
      at: baseAt,
    })
  }

  actions.push({
    type: "deposit",
    walletId: "wallet-lend-stress-99",
    marketId: marketIds[0]!,
    depositAmount: 999_999_999,
    walletBalance: 1,
    at: state.now + 999_999,
  })

  return actions
}
