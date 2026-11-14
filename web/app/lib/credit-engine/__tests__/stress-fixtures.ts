import type { BorrowAction, BorrowSystemState } from "@/app/lib/credit-engine"
import { RAY, USD_SCALE, WAD, parseFixed } from "@/app/lib/credit-engine"
import { makeExampleBorrowSystemState } from "./fixtures"

function usdFromInt(value: number) {
  return BigInt(value) * USD_SCALE
}

function tokenFromInt(value: number) {
  return BigInt(value) * WAD
}

export function makeStressBorrowSystemState(userCount = 1000): BorrowSystemState {
  const state = makeExampleBorrowSystemState()
  const marketIds = Object.keys(state.markets) as Array<keyof typeof state.markets>
  const accounts: BorrowSystemState["accounts"] = {}

  for (let index = 0; index < userCount; index += 1) {
    const walletId = `wallet-stress-${index}`
    const marketId = marketIds[index % marketIds.length]!
    const market = state.markets[marketId]!
    const assetId = market.relations.supportedBorrowAssetIds[index % market.relations.supportedBorrowAssetIds.length]!
    const asset = state.assets[assetId]!
    const collateralTokens = 5 + (index % 8)
    const baseDebtUsd = 600 + (index % 7) * 125

    accounts[walletId] = {
      walletId,
      walletBalanceUsd6: usdFromInt(2500 + (index % 10) * 150),
      walletLpBalancesUsd6: {
        [marketId]: usdFromInt(5000 + (index % 8) * 250),
      },
      interestSettledUsd6: 0n,
      lastUpdatedAt: state.now - 60_000,
      collateralPositions: [
        {
          id: `${walletId}:${marketId}`,
          marketId,
          collateralShares: tokenFromInt(collateralTokens),
          principalTokenAmount: tokenFromInt(collateralTokens),
          collateralEnabled: true,
        },
      ],
      debtPositions: [
        {
          id: `${walletId}:${assetId}`,
          assetId,
          baseAssetId: asset.baseAssetId,
          spokeId: asset.spokeId,
          marketId,
          debtSharesUsd6: usdFromInt(baseDebtUsd),
          debtIndexRay: RAY,
          borrowRateWad: asset.borrowConfig.baseBorrowAprWad,
          principalBorrowedUsd6: usdFromInt(baseDebtUsd),
        },
      ],
      rewardPositions: [],
    }
  }

  return {
    ...state,
    accounts,
    transactions: [],
  }
}

export function makeStressBorrowActions(state: BorrowSystemState): BorrowAction[] {
  const actions: BorrowAction[] = []
  const walletIds = Object.keys(state.accounts)

  for (let index = 0; index < walletIds.length; index += 1) {
    const walletId = walletIds[index]!
    const account = state.accounts[walletId]!
    const collateral = account.collateralPositions[0]!
    const debt = account.debtPositions[0]!
    const market = state.markets[collateral.marketId]!
    const assetId = market.relations.supportedBorrowAssetIds[0]!
    const baseAt = state.now + index * 1000

    actions.push({
      type: "supplyCollateral",
      walletId,
      marketId: collateral.marketId,
      amountUsd6: parseFixed(`${150 + (index % 5) * 25}`, 6),
      at: baseAt,
    })

    actions.push({
      type: "borrow",
      walletId,
      marketId: collateral.marketId,
      assetId,
      amountUsd6: parseFixed(`${40 + (index % 4) * 10}`, 6),
      at: baseAt + 1,
    })

    if (index % 3 === 0) {
      actions.push({
        type: "repay",
        walletId,
        debtPositionId: debt.id,
        amountUsd6: parseFixed("20", 6),
        at: baseAt + 2,
      })
    }

    if (index % 5 === 0) {
      actions.push({
        type: "removeCollateral",
        walletId,
        positionId: collateral.id,
        percentBps: 200,
        at: baseAt + 3,
      })
    }
  }

  return actions
}

export function makeHeterogeneousStressBorrowSystemState(userCount = 10_000): BorrowSystemState {
  const state = makeExampleBorrowSystemState()
  const marketIds = Object.keys(state.markets) as Array<keyof typeof state.markets>
  const accounts: BorrowSystemState["accounts"] = {}

  for (let index = 0; index < userCount; index += 1) {
    const walletId = `wallet-stress-${index}`
    const primaryMarketId = marketIds[index % marketIds.length]!
    const secondaryMarketId = marketIds[(index + 1) % marketIds.length]!
    const primaryMarket = state.markets[primaryMarketId]!
    const primaryAssetId =
      primaryMarket.relations.supportedBorrowAssetIds[index % primaryMarket.relations.supportedBorrowAssetIds.length]!
    const primaryAsset = state.assets[primaryAssetId]!
    const isWhale = index % 125 === 0
    const multiSpoke = index % 2 === 0
    const primaryCollateralTokens = isWhale ? 500 + (index % 25) * 10 : 6 + (index % 11)
    const secondaryCollateralTokens = multiSpoke ? 4 + (index % 5) : 0
    const primaryDebtUsd = isWhale ? 120_000 + (index % 7) * 15_000 : 550 + (index % 9) * 140

    accounts[walletId] = {
      walletId,
      walletBalanceUsd6: usdFromInt(isWhale ? 1_000_000 : 4_000 + (index % 12) * 250),
      walletLpBalancesUsd6: {
        [primaryMarketId]: usdFromInt(isWhale ? 150_000 : 8_000 + (index % 9) * 500),
        ...(multiSpoke ? { [secondaryMarketId]: usdFromInt(6_000 + (index % 5) * 400) } : {}),
      },
      interestSettledUsd6: 0n,
      lastUpdatedAt: state.now - 60_000,
      collateralPositions: [
        {
          id: `${walletId}:${primaryMarketId}`,
          marketId: primaryMarketId,
          collateralShares: tokenFromInt(primaryCollateralTokens),
          principalTokenAmount: tokenFromInt(primaryCollateralTokens),
          collateralEnabled: true,
        },
        ...(multiSpoke
          ? [
              {
                id: `${walletId}:${secondaryMarketId}`,
                marketId: secondaryMarketId,
                collateralShares: tokenFromInt(secondaryCollateralTokens),
                principalTokenAmount: tokenFromInt(secondaryCollateralTokens),
                collateralEnabled: true,
              },
            ]
          : []),
      ],
      debtPositions: [
        {
          id: `${walletId}:${primaryAssetId}`,
          assetId: primaryAssetId,
          baseAssetId: primaryAsset.baseAssetId,
          spokeId: primaryAsset.spokeId,
          marketId: primaryMarketId,
          debtSharesUsd6: usdFromInt(primaryDebtUsd),
          debtIndexRay: RAY,
          borrowRateWad: primaryAsset.borrowConfig.baseBorrowAprWad,
          principalBorrowedUsd6: usdFromInt(primaryDebtUsd),
        },
      ],
      rewardPositions: [],
    }
  }

  return {
    ...state,
    accounts,
    transactions: [],
  }
}

export function makeHeterogeneousStressBorrowActions(
  state: BorrowSystemState,
  activeWalletCount = Object.keys(state.accounts).length,
): BorrowAction[] {
  const actions: BorrowAction[] = []
  const walletIds = Object.keys(state.accounts).slice(0, activeWalletCount)

  for (let index = 0; index < walletIds.length; index += 1) {
    const walletId = walletIds[index]!
    const account = state.accounts[walletId]!
    const primaryCollateral = account.collateralPositions[0]!
    const secondaryCollateral = account.collateralPositions[1] ?? null
    const debt = account.debtPositions[0]!
    const market = state.markets[primaryCollateral.marketId]!
    const assetId = market.relations.supportedBorrowAssetIds[index % market.relations.supportedBorrowAssetIds.length]!
    const isWhale = index % 125 === 0
    const baseAt = state.now + index * 10

    actions.push({
      type: "supplyCollateral",
      walletId,
      marketId: primaryCollateral.marketId,
      amountUsd6: parseFixed(isWhale ? "25000" : `${175 + (index % 6) * 35}`, 6),
      at: baseAt,
    })

    actions.push({
      type: "borrow",
      walletId,
      marketId: primaryCollateral.marketId,
      assetId,
      amountUsd6: parseFixed(isWhale ? "1200" : `${50 + (index % 5) * 12}`, 6),
      at: baseAt + 1,
    })

    actions.push({
      type: "repay",
      walletId,
      debtPositionId: debt.id,
      amountUsd6: parseFixed(isWhale ? "800" : `${25 + (index % 4) * 5}`, 6),
      at: baseAt + 2,
    })

    if (secondaryCollateral) {
      actions.push({
        type: "removeCollateral",
        walletId,
        positionId: secondaryCollateral.id,
        percentBps: 125,
        at: baseAt + 3,
      })
    } else if (index % 3 === 0) {
      actions.push({
        type: "removeCollateral",
        walletId,
        positionId: primaryCollateral.id,
        percentBps: 75,
        at: baseAt + 3,
      })
    }
  }

  return actions
}
