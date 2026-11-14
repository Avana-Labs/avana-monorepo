import {
  accrueBorrowSystemState,
  calculateSpokeCreditMetrics,
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  formatFixed,
  mulDiv,
  parseFixed,
  simulateBorrow,
  simulateDeposit,
  simulateRepay,
  simulateWithdraw,
  type BorrowSystemState,
} from "@/app/lib/credit-engine"

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

function healthFactorToNumber(value: bigint | null) {
  return value == null ? null : fixedToNumber(value, 18)
}

// Repaying the displayed Max can land a hair off the true debt: the outstanding
// figure is shown rounded to cents and the token Max is floored to 6 dp. Treat any
// amount within a cent of the debt as a full repay so the position closes cleanly.
const REPAY_FULL_CLOSE_EPSILON_USD = 0.01

export function buildBorrowPreviewModel(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  assetId: string | null,
  amountUsd: number,
) {
  if (amountUsd <= 0 || !assetId) {
    return {
      isEmpty: amountUsd <= 0,
      isValid: false,
      exceedsBorrowPower: false,
      healthFactor: null as number | null,
      remainingBorrowPowerUsd: 0,
      progressPercent: 5,
      warningMessage: null as string | null,
    }
  }

  const preview = simulateBorrow(state, {
    type: "borrow",
    walletId,
    marketId,
    assetId,
    amountUsd6: parseFixed(amountUsd.toFixed(6), 6),
  })

  return {
    isEmpty: false,
    isValid: preview.allowed,
    exceedsBorrowPower: !preview.allowed,
    healthFactor: healthFactorToNumber(preview.after.metrics.healthFactorWad),
    remainingBorrowPowerUsd: fixedToNumber(preview.after.metrics.availableBorrowCapacityUsd6, 6),
    progressPercent:
      preview.before.metrics.borrowCapacityUsd6 > 0n
        ? Math.min(
            100,
            (fixedToNumber(preview.after.metrics.totalBorrowedUsd6, 6) /
              fixedToNumber(preview.before.metrics.borrowCapacityUsd6, 6)) *
              100,
          )
        : 0,
    warningMessage: preview.validationErrors[0] ?? preview.warnings[0] ?? null,
  }
}

export function buildRepayPreviewModel(
  sessionState: BorrowSystemState,
  walletId: string,
  debtPositionId: string | null,
  amountUsd: number,
  now = Date.now(),
) {
  // Owed includes interest accrued since the last write, matching the repay intent (at: now).
  const state = accrueBorrowSystemState(sessionState, now)
  const debtPosition = debtPositionId
    ? (state.accounts[walletId]?.debtPositions.find((position) => position.id === debtPositionId) ?? null)
    : null
  const currentDebtUsd = debtPosition ? fixedToNumber(currentDebtValueUsd6(debtPosition), 6) : 0

  if (amountUsd <= 0 || !debtPosition) {
    return {
      isEmpty: amountUsd <= 0,
      isValid: false,
      exceedsDebt: amountUsd > currentDebtUsd,
      remainingDebtUsd: currentDebtUsd,
      healthFactorAfter: null as number | null,
      yearlyInterestSavedUsd: 0,
      warningMessage: debtPosition ? null : "No debt selected",
    }
  }

  // Within a cent of the outstanding debt counts as a full repay: clamp to the exact
  // debt so the displayed Max closes the position rather than tripping "exceeds debt"
  // (2-dp display vs full-precision guard) or leaving dust behind.
  const effectiveAmountUsd =
    Math.abs(amountUsd - currentDebtUsd) <= REPAY_FULL_CLOSE_EPSILON_USD ? currentDebtUsd : amountUsd

  const preview = simulateRepay(state, {
    type: "repay",
    walletId,
    debtPositionId: debtPosition.id,
    amountUsd6: parseFixed(effectiveAmountUsd.toFixed(6), 6),
  })
  const nextPosition =
    preview.after.state.accounts[walletId]?.debtPositions.find((position) => position.id === debtPosition.id) ?? null

  return {
    isEmpty: false,
    isValid: preview.allowed && effectiveAmountUsd <= currentDebtUsd,
    exceedsDebt: effectiveAmountUsd > currentDebtUsd,
    remainingDebtUsd: nextPosition ? fixedToNumber(currentDebtValueUsd6(nextPosition), 6) : 0,
    healthFactorAfter: healthFactorToNumber(preview.after.metrics.healthFactorWad),
    yearlyInterestSavedUsd: debtPosition
      ? Math.min(effectiveAmountUsd, currentDebtUsd) * fixedToNumber(debtPosition.borrowRateWad, 18)
      : 0,
    warningMessage: preview.validationErrors[0] ?? preview.warnings[0] ?? null,
  }
}

export function buildWithdrawPreviewModel(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  percent: number,
) {
  const position = state.accounts[walletId]?.collateralPositions.find((entry) => entry.marketId === marketId) ?? null
  const market = state.markets[marketId]
  if (!position || !market || percent <= 0) {
    return {
      isUnsafe: false,
      healthFactorAfter: null as number | null,
      removeUsd: 0,
      afterCollateralUsd: position && market ? fixedToNumber(currentCollateralValueUsd6(position, market), 6) : 0,
      safePercent: 0,
      warningMessage: null as string | null,
    }
  }

  const currentCollateralUsd = fixedToNumber(currentCollateralValueUsd6(position, market), 6)
  const currentMetrics = calculateSpokeCreditMetrics(state, walletId, market.spokeId)
  const liquidationHeadroomUsd6 =
    currentMetrics.liquidationValueUsd6 > currentMetrics.totalBorrowedUsd6
      ? currentMetrics.liquidationValueUsd6 - currentMetrics.totalBorrowedUsd6
      : 0n
  const maxRemoveUsd6 =
    currentMetrics.totalBorrowedUsd6 > 0n
      ? mulDiv(liquidationHeadroomUsd6, parseFixed("1", 18), market.riskConfig.liquidationThresholdWad)
      : currentCollateralValueUsd6(position, market)
  const safePercent =
    currentCollateralUsd > 0
      ? Math.max(0, Math.min(100, Math.floor((fixedToNumber(maxRemoveUsd6, 6) / currentCollateralUsd) * 100)))
      : 0
  const preview = simulateWithdraw(state, {
    type: "removeCollateral",
    walletId,
    positionId: position.id,
    percentBps: percent * 100,
  })

  return {
    isUnsafe: !preview.allowed,
    healthFactorAfter: healthFactorToNumber(preview.after.metrics.healthFactorWad),
    removeUsd: Math.round((currentCollateralUsd * percent) / 100),
    afterCollateralUsd: fixedToNumber(preview.after.metrics.collateralValueUsd6, 6),
    safePercent,
    warningMessage: preview.validationErrors[0] ?? preview.warnings[0] ?? null,
  }
}

export function buildDepositPreviewModel(
  state: BorrowSystemState,
  walletId: string,
  marketId: string,
  amountUsd: number,
) {
  if (amountUsd <= 0) {
    return {
      isEmpty: true,
      isValid: false,
      borrowCapacityUsd: 0,
      borrowPowerDeltaUsd: 0,
      collateralValueUsd: 0,
      healthFactor: null as number | null,
      warningMessage: null as string | null,
    }
  }

  const preview = simulateDeposit(state, {
    type: "supplyCollateral",
    walletId,
    marketId,
    amountUsd6: parseFixed(amountUsd.toFixed(6), 6),
  })

  return {
    isEmpty: false,
    isValid: preview.allowed,
    borrowCapacityUsd: fixedToNumber(preview.after.metrics.borrowCapacityUsd6, 6),
    borrowPowerDeltaUsd: fixedToNumber(
      preview.after.metrics.availableBorrowCapacityUsd6 - preview.before.metrics.availableBorrowCapacityUsd6,
      6,
    ),
    collateralValueUsd: fixedToNumber(preview.after.metrics.collateralValueUsd6, 6),
    healthFactor: healthFactorToNumber(preview.after.metrics.healthFactorWad),
    warningMessage: preview.validationErrors[0] ?? preview.warnings[0] ?? null,
  }
}
