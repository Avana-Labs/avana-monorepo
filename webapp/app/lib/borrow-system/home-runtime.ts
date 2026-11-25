import {
  calculateSpokeCreditMetrics,
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  formatFixed,
  mulDiv,
  parseFixed,
  type BorrowAction,
  type BorrowSystemState,
  type UserCollateralPosition,
  type UserDebtPosition,
} from "@/app/lib/borrow-system/model"
import {
  calculateClaimPreview,
  formatCompactUsd,
  formatHealthFactor,
  formatUsd,
  getRiskTone,
  type BorrowPreview,
  type ClaimPreview,
  type HomeBorrowToken,
  type HomeClaimPosition,
  type RemovePreview,
  type RepayPreview,
} from "@/app/lib/home-view-model"
import {
  buildBorrowPreviewModel,
  buildDepositPreviewModel,
  buildRepayPreviewModel,
  buildWithdrawPreviewModel,
} from "./preview-builders"
import { selectBorrowCollateralPools, selectBorrowableAssets } from "./selectors"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

function healthFactorToNumber(healthFactorWad: bigint, totalBorrowedUsd6: bigint) {
  // Raw metrics use 0n both for no-debt and for underwater zero-liq. Only no-debt is ∞.
  if (totalBorrowedUsd6 === 0n) return Number.POSITIVE_INFINITY
  return fixedToNumber(healthFactorWad, 18)
}

function userMessageFromError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  if (message.includes("no collateral")) return "Deposit compatible collateral"
  if (message.includes("not supported")) return "Unsupported in this spoke"
  if (message.includes("enough available credit") || message.includes("insolvent")) return "Exceeds borrow power"
  if (message.includes("enough liquidity")) return "Not enough liquidity"
  if (message.includes("Unknown debt position")) return "No debt selected"
  return "Action unavailable"
}

function tokenFromAssetId(state: BorrowSystemState, assetId: string): HomeBorrowToken | null {
  const asset = state.assets[assetId]
  if (!asset) return null
  return {
    id: asset.id,
    name: asset.display.name,
    symbol: asset.symbol,
    subtitle: asset.contextLabel,
    borrowApr: fixedToNumber(asset.borrowConfig.baseBorrowAprWad, 18) * 100,
    visual: {
      symbol: asset.display.visual.symbol,
      shortLabel: asset.display.visual.shortLabel,
      bgClassName: asset.display.visual.bgClassName,
      textClassName: asset.display.visual.textClassName,
    },
  }
}

function collateralPositionForMarket(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
): UserCollateralPosition | null {
  return state.accounts[walletId]?.collateralPositions.find((position) => position.marketId === marketId) ?? null
}

function debtPositionsForSpoke(state: BorrowSystemState, walletId: string, spokeId: string): UserDebtPosition[] {
  return state.accounts[walletId]?.debtPositions.filter((position) => position.spokeId === spokeId) ?? []
}

function totalSpokeDebtUsd(state: BorrowSystemState, walletId: string, spokeId: string) {
  return debtPositionsForSpoke(state, walletId, spokeId).reduce(
    (sum, position) => sum + fixedToNumber(currentDebtValueUsd6(position), 6),
    0,
  )
}

export function selectHomeBorrowTokensForMarket(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
): HomeBorrowToken[] {
  return selectBorrowableAssets(state, walletId, marketId).map((asset) => ({
    id: asset.id,
    name: asset.name,
    symbol: asset.symbol,
    subtitle: asset.subtitle,
    borrowApr: asset.borrowApr,
    visual: {
      symbol: asset.visual.symbol,
      shortLabel: asset.visual.shortLabel,
      bgClassName: asset.visual.bgClass,
      textClassName: asset.visual.textClass,
    },
  }))
}

export function selectHomeRepayTokensForMarket(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
): HomeBorrowToken[] {
  const account = state.accounts[walletId]
  if (!account) return []

  return account.debtPositions
    .filter((position) => position.marketId === marketId)
    .map((position) => tokenFromAssetId(state, position.assetId))
    .filter((token): token is HomeBorrowToken => Boolean(token))
}

export function selectHomeDebtMap(state: BorrowSystemState, walletId: string) {
  const debtMap: Record<string, number> = {}
  for (const pool of selectBorrowCollateralPools(state, walletId)) {
    const spokeId = state.markets[pool.id]?.spokeId
    debtMap[pool.id] = spokeId ? totalSpokeDebtUsd(state, walletId, spokeId) : 0
  }
  return debtMap
}

export function buildHomeBorrowPreview(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  assetId: string | null,
  amountUsd: number,
): BorrowPreview {
  const market = state.markets[marketId]
  if (!market) {
    throw new Error(`Unknown market ${marketId}`)
  }
  const currentMetrics = calculateSpokeCreditMetrics(state, walletId, market.spokeId)
  const currentAvailableCreditUsd = fixedToNumber(currentMetrics.availableCreditUsd6, 6)

  if (amountUsd <= 0) {
    return {
      amountUsd,
      amountLabel: "—",
      isEmpty: true,
      isValid: false,
      exceedsBorrowPower: false,
      healthFactor: null,
      healthFactorLabel: "—",
      riskTone: "neutral",
      progressPercent: 5,
      remainingBorrowPowerUsd: currentAvailableCreditUsd,
      warningTitle: null,
      warningMessage: null,
      ctaLabel: "Enter an amount",
    }
  }

  if (!assetId) {
    return {
      amountUsd,
      amountLabel: formatUsd(amountUsd),
      isEmpty: false,
      isValid: false,
      exceedsBorrowPower: false,
      healthFactor: null,
      healthFactorLabel: "—",
      riskTone: "neutral",
      progressPercent: 5,
      remainingBorrowPowerUsd: currentAvailableCreditUsd,
      warningTitle: null,
      warningMessage: null,
      ctaLabel: "Select token",
    }
  }

  const model = buildBorrowPreviewModel(state, walletId, marketId, assetId, amountUsd)
  const riskTone = getRiskTone(model.healthFactor ?? Number.POSITIVE_INFINITY)

  return {
    amountUsd,
    amountLabel: formatUsd(amountUsd),
    isEmpty: model.isEmpty,
    isValid: model.isValid,
    exceedsBorrowPower: model.exceedsBorrowPower,
    healthFactor: model.healthFactor,
    healthFactorLabel: formatHealthFactor(model.healthFactor),
    riskTone,
    progressPercent: model.progressPercent,
    remainingBorrowPowerUsd: model.remainingBorrowPowerUsd || currentAvailableCreditUsd,
    warningTitle:
      model.warningMessage != null
        ? model.isValid
          ? riskTone === "danger"
            ? "High liquidation risk"
            : "Borrowing gets tighter"
          : "Borrow unavailable"
        : null,
    warningMessage: model.warningMessage,
    ctaLabel: model.isValid
      ? `Borrow ${amountUsd.toFixed(0)} ${state.assets[assetId]?.symbol ?? "tokens"}`
      : userMessageFromError(model.warningMessage ?? "Action unavailable"),
  }
}

export function buildHomeRepayPreview(
  state: BorrowSystemState,
  walletId: string,
  debtPositionId: string | null,
  amountUsd: number,
): RepayPreview {
  const debtPosition = debtPositionId
    ? (state.accounts[walletId]?.debtPositions.find((position) => position.id === debtPositionId) ?? null)
    : null
  const currentDebtUsd = debtPosition ? fixedToNumber(currentDebtValueUsd6(debtPosition), 6) : 0
  const spokeId = debtPosition?.spokeId
  const currentMetrics = spokeId ? calculateSpokeCreditMetrics(state, walletId, spokeId) : null
  const currentHealthFactor = currentMetrics
    ? healthFactorToNumber(currentMetrics.healthFactorWad, currentMetrics.totalBorrowedUsd6)
    : Number.POSITIVE_INFINITY
  const exceedsDebt = amountUsd > currentDebtUsd

  if (amountUsd <= 0) {
    return {
      amountUsd,
      isEmpty: true,
      isValid: false,
      exceedsDebt: false,
      remainingDebtUsd: currentDebtUsd,
      remainingDebtLabel: formatCompactUsd(currentDebtUsd),
      healthFactorAfter: currentHealthFactor,
      healthFactorAfterLabel: formatHealthFactor(currentHealthFactor),
      oldHealthFactorLabel: formatHealthFactor(currentHealthFactor),
      riskTone: getRiskTone(currentHealthFactor),
      yearlyInterestSavedUsd: 0,
      ctaLabel: "Enter an amount",
    }
  }

  if (!debtPosition) {
    return {
      amountUsd,
      isEmpty: false,
      isValid: false,
      exceedsDebt,
      remainingDebtUsd: 0,
      remainingDebtLabel: "$0",
      healthFactorAfter: currentHealthFactor,
      healthFactorAfterLabel: formatHealthFactor(currentHealthFactor),
      oldHealthFactorLabel: formatHealthFactor(currentHealthFactor),
      riskTone: "neutral",
      yearlyInterestSavedUsd: 0,
      ctaLabel: "No debt selected",
    }
  }

  const model = buildRepayPreviewModel(state, walletId, debtPosition.id, amountUsd)
  const healthFactorAfter = model.healthFactorAfter ?? currentHealthFactor

  return {
    amountUsd,
    isEmpty: model.isEmpty,
    isValid: model.isValid,
    exceedsDebt: model.exceedsDebt,
    remainingDebtUsd: model.remainingDebtUsd,
    remainingDebtLabel:
      `${formatCompactUsd(model.remainingDebtUsd)} ${state.assets[debtPosition.assetId]?.symbol ?? ""}`.trim(),
    healthFactorAfter,
    healthFactorAfterLabel: formatHealthFactor(healthFactorAfter),
    oldHealthFactorLabel: formatHealthFactor(currentHealthFactor),
    riskTone: getRiskTone(healthFactorAfter),
    yearlyInterestSavedUsd: model.yearlyInterestSavedUsd,
    ctaLabel: model.isValid
      ? `Repay ${formatCompactUsd(Math.min(amountUsd, currentDebtUsd))} ${state.assets[debtPosition.assetId]?.symbol ?? ""}`.trim()
      : userMessageFromError(model.warningMessage ?? "Action unavailable"),
  }
}

export function buildHomeRemovePreview(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  percent: number,
): RemovePreview {
  const market = state.markets[marketId]
  const position = collateralPositionForMarket(state, walletId, marketId)
  if (!market || !position) {
    return {
      percent,
      safePercent: 0,
      removeUsd: 0,
      afterCollateralUsd: 0,
      healthFactorAfter: null,
      healthFactorAfterLabel: "—",
      riskTone: "neutral",
      isUnsafe: false,
      isValid: false,
      liquidationThresholdAfterUsd: 0,
      ctaLabel: "No collateral supplied",
    }
  }

  const currentMetrics = calculateSpokeCreditMetrics(state, walletId, market.spokeId)
  const currentValueUsd = fixedToNumber(currentCollateralValueUsd6(position, market), 6)
  const removeUsd = Math.round((currentValueUsd * percent) / 100)
  const afterCollateralUsd = Math.max(0, currentValueUsd - removeUsd)
  const liquidationHeadroomUsd6 =
    currentMetrics.liquidationValueUsd6 > currentMetrics.totalBorrowedUsd6
      ? currentMetrics.liquidationValueUsd6 - currentMetrics.totalBorrowedUsd6
      : 0n
  const maxRemoveUsd6 =
    currentMetrics.totalBorrowedUsd6 > 0n
      ? mulDiv(liquidationHeadroomUsd6, parseFixed("1", 18), market.riskConfig.liquidationThresholdWad)
      : currentCollateralValueUsd6(position, market)
  const safePercent =
    currentValueUsd > 0
      ? Math.max(0, Math.min(100, Math.floor((fixedToNumber(maxRemoveUsd6, 6) / currentValueUsd) * 100)))
      : 0
  if (percent <= 0) {
    const currentHealthFactor = healthFactorToNumber(currentMetrics.healthFactorWad, currentMetrics.totalBorrowedUsd6)
    return {
      percent,
      safePercent,
      removeUsd: 0,
      afterCollateralUsd: currentValueUsd,
      healthFactorAfter: currentHealthFactor,
      healthFactorAfterLabel: formatHealthFactor(currentHealthFactor),
      riskTone: getRiskTone(currentHealthFactor),
      isUnsafe: false,
      isValid: false,
      liquidationThresholdAfterUsd: fixedToNumber(currentMetrics.liquidationValueUsd6, 6),
      ctaLabel: "Remove 0% · $0",
    }
  }

  const model = buildWithdrawPreviewModel(state, walletId, marketId, percent)
  const healthFactorAfter =
    model.healthFactorAfter ?? healthFactorToNumber(currentMetrics.healthFactorWad, currentMetrics.totalBorrowedUsd6)

  // Block removals that breach the safe headroom or would leave the position
  // insolvent (HF-after < 1.0). Consistent with the credit engine, which throws
  // on unsafe collateral removal — surface it as a blocked CTA, not a live one.
  const isValid = !model.isUnsafe && (healthFactorAfter == null || healthFactorAfter >= 1.0)

  return {
    percent,
    safePercent,
    removeUsd,
    afterCollateralUsd: model.afterCollateralUsd || afterCollateralUsd,
    healthFactorAfter,
    healthFactorAfterLabel: formatHealthFactor(healthFactorAfter),
    riskTone: model.isUnsafe ? "danger" : getRiskTone(healthFactorAfter),
    isUnsafe: model.isUnsafe,
    isValid,
    liquidationThresholdAfterUsd: fixedToNumber(currentMetrics.liquidationValueUsd6, 6),
    ctaLabel: isValid ? `Remove ${percent}% · ${formatCompactUsd(removeUsd)}` : "Reduce removal amount",
  }
}

/**
 * Adapter-backed claim preview sourced from engine reward positions.
 */
export function selectRewardClaimableTotals(state: BorrowSystemState, walletId: string): Record<string, number> {
  const account = state.accounts[walletId]
  if (!account) return {}
  const rewardPositions = account.rewardPositions ?? []
  const claimableTotals: Record<string, number> = {}
  for (const position of rewardPositions) {
    claimableTotals[position.id] = fixedToNumber(position.claimableUsd6, 6)
  }
  return claimableTotals
}

export function buildClaimBorrowAction(walletId: string, preview: ClaimPreview): BorrowAction | null {
  if (!preview.hasSelection || preview.effectiveClaimUsd <= 0) {
    return null
  }

  return {
    type: "claim",
    walletId,
    rewardPositionIds: preview.selectedPositionIds,
    amountUsd6: parseFixed(preview.effectiveClaimUsd.toFixed(6), 6),
  }
}

export function buildHomeClaimPreview(
  state: BorrowSystemState,
  walletId: string,
  positions: Array<Pick<HomeClaimPosition, "id"> & Partial<Pick<HomeClaimPosition, "breakdown">>>,
  selections: Record<string, boolean>,
  partialAmountUsd: number | null,
): ClaimPreview {
  const engineTotals = selectRewardClaimableTotals(state, walletId)
  const claimableTotals: Record<string, number> = {}
  for (const position of positions) {
    claimableTotals[position.id] = engineTotals[position.id] ?? 0
  }
  return calculateClaimPreview(
    positions.map((position) => ({
      id: position.id,
      poolId: "",
      name: "",
      subtitle: "",
      totalUsd: claimableTotals[position.id] ?? 0,
      breakdown: position.breakdown ?? [],
    })),
    claimableTotals,
    selections,
    partialAmountUsd,
  )
}

type SupplyPreview = {
  amountUsd: number
  isEmpty: boolean
  isValid: boolean
  borrowPowerUsd: number
  collateralValueUsd: number
  healthFactor: number | null
  healthFactorLabel: string
  riskTone: ReturnType<typeof getRiskTone>
  warningMessage: string | null
  ctaLabel: string
}

export function buildHomeSupplyPreview(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  amountUsd: number,
): SupplyPreview {
  if (amountUsd <= 0) {
    return {
      amountUsd,
      isEmpty: true,
      isValid: false,
      borrowPowerUsd: 0,
      collateralValueUsd: 0,
      healthFactor: null,
      healthFactorLabel: "—",
      riskTone: "neutral",
      warningMessage: null,
      ctaLabel: "Enter an amount",
    }
  }

  const model = buildDepositPreviewModel(state, walletId, marketId, amountUsd)

  return {
    amountUsd,
    isEmpty: model.isEmpty,
    isValid: model.isValid,
    borrowPowerUsd: model.borrowPowerDeltaUsd,
    collateralValueUsd: model.collateralValueUsd,
    healthFactor: model.healthFactor,
    healthFactorLabel: formatHealthFactor(model.healthFactor),
    riskTone: getRiskTone(model.healthFactor ?? Number.POSITIVE_INFINITY),
    warningMessage: model.warningMessage,
    ctaLabel: model.isValid ? "Review pledge" : (model.warningMessage ?? "Action unavailable"),
  }
}
