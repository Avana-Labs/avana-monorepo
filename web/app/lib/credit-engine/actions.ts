import { accrueBorrowSystemState } from "./accrue"
import { calculateCreditMetrics, calculateSpokeCreditMetrics } from "./metrics"
import type { BorrowAction, BorrowSystemState } from "./types"
import { RAY, TOKEN_SCALE, WAD, assetsToShares, mulDiv } from "./units"
import { currentCollateralValueUsd6, currentDebtValueUsd6, debtInterestOwedUsd6 } from "./valuation"

function cloneState(state: BorrowSystemState): BorrowSystemState {
  const markets: BorrowSystemState["markets"] = {}
  for (const [id, market] of Object.entries(state.markets)) {
    markets[id] = { ...market, snapshot: { ...market.snapshot } }
  }

  const assets: BorrowSystemState["assets"] = {}
  for (const [id, asset] of Object.entries(state.assets)) {
    assets[id] = { ...asset, snapshot: { ...asset.snapshot }, borrowConfig: { ...asset.borrowConfig } }
  }

  const accounts: BorrowSystemState["accounts"] = {}
  for (const [id, account] of Object.entries(state.accounts)) {
    accounts[id] = {
      ...account,
      walletLpBalancesUsd6: { ...(account.walletLpBalancesUsd6 ?? {}) },
      walletReturnedLpBalancesUsd6: { ...(account.walletReturnedLpBalancesUsd6 ?? {}) },
      collateralPositions: (account.collateralPositions ?? []).map((position) => ({ ...position })),
      debtPositions: (account.debtPositions ?? []).map((position) => ({ ...position })),
      rewardPositions: (account.rewardPositions ?? []).map((position) => ({ ...position })),
    }
  }

  return {
    ...state,
    markets,
    assets,
    accounts,
    transactions: [...state.transactions],
  }
}

function syncBorrowRates(state: BorrowSystemState, walletId: string) {
  const account = state.accounts[walletId]
  if (!account || account.debtPositions.length === 0) return
  account.debtPositions = account.debtPositions.map((position) => ({
    ...position,
    borrowRateWad:
      state.assets[position.assetId]!.borrowConfig.baseBorrowAprWad +
      calculateSpokeCreditMetrics(state, walletId, position.spokeId).riskPremiumWad,
  }))
}

function usd6ToTokenAmount(amountUsd6: bigint, lpTokenPriceUsd6: bigint) {
  return mulDiv(amountUsd6, TOKEN_SCALE, lpTokenPriceUsd6)
}

function hasCollateralInSpoke(state: BorrowSystemState, walletId: string, spokeId: string) {
  const account = state.accounts[walletId]
  if (!account) return false
  return account.collateralPositions.some(
    (position) => position.collateralEnabled && state.markets[position.marketId]?.spokeId === spokeId,
  )
}

function applyBorrowDebtAction(state: BorrowSystemState, action: Extract<BorrowAction, { type: "borrow" }>) {
  const market = state.markets[action.marketId]
  const asset = state.assets[action.assetId]
  const account = state.accounts[action.walletId]

  if (!market) throw new Error(`Unknown market ${action.marketId}`)
  if (!asset) throw new Error(`Unknown asset ${action.assetId}`)
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)
  if (asset.spokeId !== market.spokeId) {
    throw new Error(`Asset ${action.assetId} does not belong to spoke ${market.spokeId}`)
  }
  if (!market.relations.supportedBorrowAssetIds.includes(action.assetId)) {
    throw new Error(`Asset ${action.assetId} is not supported by market ${action.marketId}`)
  }
  if (action.amountUsd6 <= 0n) throw new Error("Borrow amount must be positive")
  if (asset.snapshot.availableLiquidityUsd6 < action.amountUsd6) {
    throw new Error(`Asset ${action.assetId} does not have enough liquidity`)
  }
  if (!hasCollateralInSpoke(state, action.walletId, market.spokeId)) {
    throw new Error(`Wallet ${action.walletId} has no collateral in spoke ${market.spokeId}`)
  }

  const currentMetrics = calculateSpokeCreditMetrics(state, action.walletId, market.spokeId)
  if (currentMetrics.availableCreditUsd6 < action.amountUsd6) {
    throw new Error(`Wallet ${action.walletId} does not have enough available credit in spoke ${market.spokeId}`)
  }

  const existing = account.debtPositions.find(
    (position) => position.assetId === action.assetId && position.spokeId === market.spokeId,
  )
  const debtIndexRay = existing?.debtIndexRay ?? RAY
  const debtSharesUsd6 = assetsToShares(action.amountUsd6, debtIndexRay)

  if (existing) {
    existing.debtSharesUsd6 += debtSharesUsd6
    existing.principalBorrowedUsd6 += action.amountUsd6
    existing.marketId = existing.marketId ?? action.marketId
  } else {
    account.debtPositions.push({
      id: `${action.walletId}:${action.assetId}`,
      assetId: action.assetId,
      baseAssetId: asset.baseAssetId,
      spokeId: market.spokeId,
      marketId: action.marketId,
      debtSharesUsd6,
      debtIndexRay,
      borrowRateWad: asset.borrowConfig.baseBorrowAprWad,
      principalBorrowedUsd6: action.amountUsd6,
      // Capture the borrowed asset's price so the debt can be repriced to spot later (§7 / D2).
      priceAtBorrowUsd6: asset.snapshot.priceUsd6,
    })
  }

  asset.snapshot.availableLiquidityUsd6 -= action.amountUsd6
  asset.snapshot.totalBorrowedUsd6 += action.amountUsd6
  asset.snapshot.totalDebtSharesUsd6 += debtSharesUsd6
  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: market.spokeId,
    marketId: action.marketId,
    assetId: action.assetId,
    kind: "borrow",
    amountUsd6: action.amountUsd6,
    at: action.at ?? state.now,
  })

  const postBorrowMetrics = calculateSpokeCreditMetrics(state, action.walletId, market.spokeId)
  if (postBorrowMetrics.totalBorrowedUsd6 > 0n && postBorrowMetrics.healthFactorWad <= WAD) {
    throw new Error(`Borrowing would make spoke ${market.spokeId} insolvent`)
  }

  // Borrowed funds land in the wallet as spendable balance.
  account.walletBalanceUsd6 += action.amountUsd6

  syncBorrowRates(state, action.walletId)
  return state
}

function applySupplyCollateralAction(
  state: BorrowSystemState,
  action: Extract<BorrowAction, { type: "supplyCollateral" }>,
) {
  const market = state.markets[action.marketId]
  const account = state.accounts[action.walletId]

  if (!market) throw new Error(`Unknown market ${action.marketId}`)
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)
  if (action.amountUsd6 <= 0n) throw new Error("Supply amount must be positive")
  const walletLpBalanceUsd6 = account.walletLpBalancesUsd6[action.marketId] ?? 0n
  if (walletLpBalanceUsd6 < action.amountUsd6) {
    throw new Error("Wallet has insufficient LP balance for this collateral deposit")
  }

  const tokenAmount = usd6ToTokenAmount(action.amountUsd6, market.snapshot.lpTokenPriceUsd6)
  const collateralShares = assetsToShares(tokenAmount, market.snapshot.supplyIndexRay)
  const existing = account.collateralPositions.find((position) => position.marketId === action.marketId)

  if (existing) {
    existing.collateralShares += collateralShares
    existing.principalTokenAmount += tokenAmount
  } else {
    account.collateralPositions.push({
      id: `${action.walletId}:${action.marketId}:collateral`,
      marketId: action.marketId,
      collateralShares,
      principalTokenAmount: tokenAmount,
      collateralEnabled: true,
    })
  }

  market.snapshot.totalCollateralShares += collateralShares
  market.snapshot.totalLiquidityUsd6 += action.amountUsd6
  market.snapshot.availableUsd6 += action.amountUsd6
  account.walletLpBalancesUsd6[action.marketId] = walletLpBalanceUsd6 - action.amountUsd6
  const returnedLpBalanceUsd6 = account.walletReturnedLpBalancesUsd6?.[action.marketId] ?? 0n
  if (returnedLpBalanceUsd6 > 0n) {
    const consumedReturnedLpUsd6 = returnedLpBalanceUsd6 > action.amountUsd6 ? action.amountUsd6 : returnedLpBalanceUsd6
    account.walletReturnedLpBalancesUsd6 = {
      ...(account.walletReturnedLpBalancesUsd6 ?? {}),
      [action.marketId]: returnedLpBalanceUsd6 - consumedReturnedLpUsd6,
    }
  }
  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: market.spokeId,
    marketId: action.marketId,
    kind: "deposit",
    amountUsd6: action.amountUsd6,
    at: action.at ?? state.now,
  })

  syncBorrowRates(state, action.walletId)
  return state
}

function applyRepayAction(state: BorrowSystemState, action: Extract<BorrowAction, { type: "repay" }>) {
  const account = state.accounts[action.walletId]
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)
  if (action.amountUsd6 <= 0n) throw new Error("Repay amount must be positive")

  const debtIndex = account.debtPositions.findIndex((position) => position.id === action.debtPositionId)
  if (debtIndex === -1) throw new Error(`Unknown debt position ${action.debtPositionId}`)

  const position = account.debtPositions[debtIndex]!
  const asset = state.assets[position.assetId]
  if (!asset) throw new Error(`Unknown asset ${position.assetId}`)

  const currentDebtUsd6 = currentDebtValueUsd6(position)
  // Repayment is bounded both by the outstanding debt and by what the wallet can fund.
  const cappedByDebtUsd6 = action.amountUsd6 > currentDebtUsd6 ? currentDebtUsd6 : action.amountUsd6
  const repayAmountUsd6 = cappedByDebtUsd6 > account.walletBalanceUsd6 ? account.walletBalanceUsd6 : cappedByDebtUsd6
  if (repayAmountUsd6 <= 0n) {
    throw new Error(`Wallet ${action.walletId} has insufficient balance to repay`)
  }
  const interestOwedUsd6 = debtInterestOwedUsd6(position)
  const sharesToBurn =
    repayAmountUsd6 === currentDebtUsd6
      ? position.debtSharesUsd6
      : assetsToShares(repayAmountUsd6, position.debtIndexRay)
  const principalReductionUsd6 = repayAmountUsd6 > interestOwedUsd6 ? repayAmountUsd6 - interestOwedUsd6 : 0n

  position.debtSharesUsd6 = position.debtSharesUsd6 > sharesToBurn ? position.debtSharesUsd6 - sharesToBurn : 0n
  position.principalBorrowedUsd6 =
    position.principalBorrowedUsd6 > principalReductionUsd6
      ? position.principalBorrowedUsd6 - principalReductionUsd6
      : 0n

  // Repaying spends wallet balance.
  account.walletBalanceUsd6 -= repayAmountUsd6

  asset.snapshot.availableLiquidityUsd6 += repayAmountUsd6
  asset.snapshot.totalBorrowedUsd6 =
    asset.snapshot.totalBorrowedUsd6 > repayAmountUsd6 ? asset.snapshot.totalBorrowedUsd6 - repayAmountUsd6 : 0n
  asset.snapshot.totalDebtSharesUsd6 =
    asset.snapshot.totalDebtSharesUsd6 > sharesToBurn ? asset.snapshot.totalDebtSharesUsd6 - sharesToBurn : 0n

  if (position.debtSharesUsd6 === 0n) {
    account.debtPositions.splice(debtIndex, 1)
  }

  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: position.spokeId,
    marketId: position.marketId,
    assetId: position.assetId,
    kind: "repay",
    amountUsd6: repayAmountUsd6,
    at: action.at ?? state.now,
  })

  syncBorrowRates(state, action.walletId)
  return state
}

function applyRemoveCollateralAction(
  state: BorrowSystemState,
  action: Extract<BorrowAction, { type: "removeCollateral" }>,
) {
  const account = state.accounts[action.walletId]
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)

  const positionIndex = account.collateralPositions.findIndex((position) => position.id === action.positionId)
  if (positionIndex === -1) throw new Error(`Unknown collateral position ${action.positionId}`)

  const position = account.collateralPositions[positionIndex]!
  const market = state.markets[position.marketId]
  if (!market) throw new Error(`Unknown market ${position.marketId}`)

  const currentValueUsd6 = currentCollateralValueUsd6(position, market)
  const percentBps = action.percentBps ?? 0
  if (percentBps < 0 || percentBps > 10_000) throw new Error("Remove percent must be between 0 and 10000 basis points")

  const requestedUsd6 =
    action.amountUsd6 ?? (percentBps > 0 ? mulDiv(currentValueUsd6, BigInt(percentBps), 10_000n) : 0n)
  const removeUsd6 = requestedUsd6 > currentValueUsd6 ? currentValueUsd6 : requestedUsd6
  if (removeUsd6 <= 0n) throw new Error("Remove amount must be positive")

  const tokenAmount = usd6ToTokenAmount(removeUsd6, market.snapshot.lpTokenPriceUsd6)
  const collateralShares =
    removeUsd6 >= currentValueUsd6
      ? position.collateralShares
      : assetsToShares(tokenAmount, market.snapshot.supplyIndexRay)
  const principalReduction =
    position.collateralShares > 0n
      ? mulDiv(position.principalTokenAmount, collateralShares, position.collateralShares)
      : 0n

  position.collateralShares =
    position.collateralShares > collateralShares ? position.collateralShares - collateralShares : 0n
  position.principalTokenAmount =
    position.principalTokenAmount > principalReduction ? position.principalTokenAmount - principalReduction : 0n

  market.snapshot.totalCollateralShares =
    market.snapshot.totalCollateralShares > collateralShares
      ? market.snapshot.totalCollateralShares - collateralShares
      : 0n
  market.snapshot.totalLiquidityUsd6 =
    market.snapshot.totalLiquidityUsd6 > removeUsd6 ? market.snapshot.totalLiquidityUsd6 - removeUsd6 : 0n
  market.snapshot.availableUsd6 =
    market.snapshot.availableUsd6 > removeUsd6 ? market.snapshot.availableUsd6 - removeUsd6 : 0n
  account.walletLpBalancesUsd6[position.marketId] = (account.walletLpBalancesUsd6[position.marketId] ?? 0n) + removeUsd6
  account.walletReturnedLpBalancesUsd6 = {
    ...(account.walletReturnedLpBalancesUsd6 ?? {}),
    [position.marketId]: (account.walletReturnedLpBalancesUsd6?.[position.marketId] ?? 0n) + removeUsd6,
  }

  if (position.collateralShares === 0n) {
    account.collateralPositions.splice(positionIndex, 1)
  }

  const walletMetrics = calculateCreditMetrics(state, action.walletId)
  if (walletMetrics.totalBorrowedUsd6 > 0n && walletMetrics.healthFactorWad <= WAD) {
    throw new Error(`Removing collateral would make wallet ${action.walletId} insolvent`)
  }

  const spokeMetrics = calculateSpokeCreditMetrics(state, action.walletId, market.spokeId)
  if (spokeMetrics.totalBorrowedUsd6 > 0n && spokeMetrics.healthFactorWad <= WAD) {
    throw new Error(`Removing collateral would make spoke ${market.spokeId} insolvent`)
  }

  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: market.spokeId,
    marketId: position.marketId,
    kind: "withdraw",
    amountUsd6: removeUsd6,
    at: action.at ?? state.now,
  })

  syncBorrowRates(state, action.walletId)
  return state
}

function applyLiquidationAction(state: BorrowSystemState, action: Extract<BorrowAction, { type: "liquidate" }>) {
  const account = state.accounts[action.walletId]
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)
  if (action.repayAmountUsd6 <= 0n) throw new Error("Liquidation repay amount must be positive")

  const collateralPosition = account.collateralPositions.find((position) => position.id === action.positionId)
  if (!collateralPosition) throw new Error(`Unknown collateral position ${action.positionId}`)
  const market = state.markets[collateralPosition.marketId]
  if (!market) throw new Error(`Unknown market ${collateralPosition.marketId}`)

  const metricsBefore = calculateSpokeCreditMetrics(state, action.walletId, market.spokeId)
  if (metricsBefore.totalBorrowedUsd6 === 0n) throw new Error(`Wallet ${action.walletId} has no debt to liquidate`)
  if (metricsBefore.healthFactorWad >= WAD) throw new Error(`Wallet ${action.walletId} is not eligible for liquidation`)

  const positionIndex = account.collateralPositions.findIndex((position) => position.id === action.positionId)
  if (positionIndex === -1) throw new Error(`Unknown collateral position ${action.positionId}`)
  const scopedCollateralPosition = account.collateralPositions[positionIndex]!

  const debtIndex =
    action.debtPositionId != null
      ? account.debtPositions.findIndex((position) => position.id === action.debtPositionId)
      : account.debtPositions.findIndex((position) => position.spokeId === market.spokeId)
  if (debtIndex === -1) throw new Error(`Unknown debt position ${action.debtPositionId ?? "(auto)"}`)

  const debtPosition = account.debtPositions[debtIndex]!
  if (debtPosition.spokeId !== market.spokeId) {
    throw new Error(`Debt position ${debtPosition.id} does not belong to spoke ${market.spokeId}`)
  }
  const asset = state.assets[debtPosition.assetId]
  if (!asset) throw new Error(`Unknown asset ${debtPosition.assetId}`)

  const currentCollateralUsd6 = currentCollateralValueUsd6(scopedCollateralPosition, market)
  const currentDebtUsd6 = currentDebtValueUsd6(debtPosition)
  const actualRepayUsd6 = [action.repayAmountUsd6, currentDebtUsd6, currentCollateralUsd6].reduce((min, value) =>
    value < min ? value : min,
  )
  if (actualRepayUsd6 <= 0n) throw new Error("Liquidation has no repayable value")

  const seizedTokenAmount = usd6ToTokenAmount(actualRepayUsd6, market.snapshot.lpTokenPriceUsd6)
  const seizedCollateralShares =
    actualRepayUsd6 >= currentCollateralUsd6
      ? collateralPosition.collateralShares
      : assetsToShares(seizedTokenAmount, market.snapshot.supplyIndexRay)
  const principalReduction =
    scopedCollateralPosition.collateralShares > 0n
      ? mulDiv(
          scopedCollateralPosition.principalTokenAmount,
          seizedCollateralShares,
          scopedCollateralPosition.collateralShares,
        )
      : 0n
  const interestOwedUsd6 = debtInterestOwedUsd6(debtPosition)
  const sharesToBurn =
    actualRepayUsd6 === currentDebtUsd6
      ? debtPosition.debtSharesUsd6
      : assetsToShares(actualRepayUsd6, debtPosition.debtIndexRay)
  const principalReductionUsd6 = actualRepayUsd6 > interestOwedUsd6 ? actualRepayUsd6 - interestOwedUsd6 : 0n

  scopedCollateralPosition.collateralShares =
    scopedCollateralPosition.collateralShares > seizedCollateralShares
      ? scopedCollateralPosition.collateralShares - seizedCollateralShares
      : 0n
  scopedCollateralPosition.principalTokenAmount =
    scopedCollateralPosition.principalTokenAmount > principalReduction
      ? scopedCollateralPosition.principalTokenAmount - principalReduction
      : 0n

  market.snapshot.totalCollateralShares =
    market.snapshot.totalCollateralShares > seizedCollateralShares
      ? market.snapshot.totalCollateralShares - seizedCollateralShares
      : 0n
  market.snapshot.totalLiquidityUsd6 =
    market.snapshot.totalLiquidityUsd6 > actualRepayUsd6 ? market.snapshot.totalLiquidityUsd6 - actualRepayUsd6 : 0n
  market.snapshot.availableUsd6 =
    market.snapshot.availableUsd6 > actualRepayUsd6 ? market.snapshot.availableUsd6 - actualRepayUsd6 : 0n

  debtPosition.debtSharesUsd6 =
    debtPosition.debtSharesUsd6 > sharesToBurn ? debtPosition.debtSharesUsd6 - sharesToBurn : 0n
  debtPosition.principalBorrowedUsd6 =
    debtPosition.principalBorrowedUsd6 > principalReductionUsd6
      ? debtPosition.principalBorrowedUsd6 - principalReductionUsd6
      : 0n

  asset.snapshot.availableLiquidityUsd6 += actualRepayUsd6
  asset.snapshot.totalBorrowedUsd6 =
    asset.snapshot.totalBorrowedUsd6 > actualRepayUsd6 ? asset.snapshot.totalBorrowedUsd6 - actualRepayUsd6 : 0n
  asset.snapshot.totalDebtSharesUsd6 =
    asset.snapshot.totalDebtSharesUsd6 > sharesToBurn ? asset.snapshot.totalDebtSharesUsd6 - sharesToBurn : 0n

  if (scopedCollateralPosition.collateralShares === 0n) {
    account.collateralPositions.splice(positionIndex, 1)
  }
  if (debtPosition.debtSharesUsd6 === 0n) {
    account.debtPositions.splice(debtIndex, 1)
  }

  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: market.spokeId,
    marketId: scopedCollateralPosition.marketId,
    assetId: debtPosition.assetId,
    kind: "liquidate",
    amountUsd6: actualRepayUsd6,
    at: action.at ?? state.now,
  })

  syncBorrowRates(state, action.walletId)
  return state
}

function applyClaimAction(state: BorrowSystemState, action: Extract<BorrowAction, { type: "claim" }>) {
  const account = state.accounts[action.walletId]
  if (!account) throw new Error(`Unknown wallet ${action.walletId}`)
  if (action.amountUsd6 <= 0n) throw new Error("Claim amount must be positive")
  if (action.rewardPositionIds.length === 0) throw new Error("Select at least one reward position to claim")

  const rewardPositions = account.rewardPositions ?? []
  const selectedPositions = action.rewardPositionIds.map((positionId) => {
    const position = rewardPositions.find((entry) => entry.id === positionId)
    if (!position) throw new Error(`Unknown reward position ${positionId}`)
    return position
  })

  const totalClaimableUsd6 = selectedPositions.reduce((sum, position) => sum + position.claimableUsd6, 0n)
  if (totalClaimableUsd6 === 0n) throw new Error("Selected reward positions have nothing to claim")

  const actualClaimUsd6 = action.amountUsd6 > totalClaimableUsd6 ? totalClaimableUsd6 : action.amountUsd6
  let remainingUsd6 = actualClaimUsd6

  for (const positionId of action.rewardPositionIds) {
    if (remainingUsd6 === 0n) break
    const position = rewardPositions.find((entry) => entry.id === positionId)
    if (!position || position.claimableUsd6 === 0n) continue

    const claimFromPosition = remainingUsd6 > position.claimableUsd6 ? position.claimableUsd6 : remainingUsd6
    position.claimableUsd6 -= claimFromPosition
    remainingUsd6 -= claimFromPosition
  }

  account.walletBalanceUsd6 += actualClaimUsd6
  const primaryMarketId = selectedPositions[0]!.marketId
  const market = state.markets[primaryMarketId]
  state.transactions.push({
    id: `tx-${state.transactions.length + 1}`,
    walletId: action.walletId,
    spokeId: market?.spokeId,
    marketId: primaryMarketId,
    kind: "claim",
    amountUsd6: actualClaimUsd6,
    at: action.at ?? state.now,
  })

  return state
}

export function applyBorrowAction(state: BorrowSystemState, action: BorrowAction): BorrowSystemState {
  const accrued = accrueBorrowSystemState(state, action.at ?? state.now)
  const next = cloneState(accrued)

  switch (action.type) {
    case "borrow":
      return applyBorrowDebtAction(next, action)
    case "supplyCollateral":
      return applySupplyCollateralAction(next, action)
    case "repay":
      return applyRepayAction(next, action)
    case "removeCollateral":
      return applyRemoveCollateralAction(next, action)
    case "liquidate":
      return applyLiquidationAction(next, action)
    case "claim":
      return applyClaimAction(next, action)
    default: {
      const exhaustiveAction: never = action
      throw new Error(`Unsupported action: ${String(exhaustiveAction)}`)
    }
  }
}
