import {
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  formatFixed,
  type BorrowSystemState,
} from "@/app/lib/borrow-system/model"
import { TRANSACTIONS_UNAVAILABLE } from "@/app/lib/borrow-system/production-transaction-adapter"

// Action previews of the Borrow flows. The after-action numbers will come from Lens
// (`previewBorrowAfter`, `previewRepayAfter`, `previewWithdrawAfter`, `previewPledgeAfter`); until
// those reads are wired every preview is "unavailable": no after-health factor, and the action
// cannot be confirmed.

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

export function buildBorrowPreviewModel(
  _state: BorrowSystemState,
  _walletId: string,
  _marketId: string,
  assetId: string | null,
  amountUsd: number,
) {
  return {
    isEmpty: amountUsd <= 0,
    isValid: false,
    exceedsBorrowPower: false,
    healthFactor: null as number | null,
    remainingBorrowPowerUsd: 0,
    progressPercent: 0,
    warningMessage: amountUsd > 0 && assetId ? TRANSACTIONS_UNAVAILABLE : (null as string | null),
  }
}

export function buildRepayPreviewModel(
  state: BorrowSystemState,
  walletId: string,
  debtPositionId: string | null,
  amountUsd: number,
) {
  const debtPosition = debtPositionId
    ? (state.accounts[walletId]?.debtPositions.find((position) => position.id === debtPositionId) ?? null)
    : null
  const currentDebtUsd = debtPosition ? fixedToNumber(currentDebtValueUsd6(debtPosition), 6) : 0
  return {
    isEmpty: amountUsd <= 0,
    isValid: false,
    exceedsDebt: amountUsd > currentDebtUsd,
    remainingDebtUsd: currentDebtUsd,
    healthFactorAfter: null as number | null,
    yearlyInterestSavedUsd: 0,
    warningMessage: debtPosition ? (amountUsd > 0 ? TRANSACTIONS_UNAVAILABLE : null) : "No debt selected",
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
  const currentCollateralUsd = position && market ? fixedToNumber(currentCollateralValueUsd6(position, market), 6) : 0
  return {
    isUnsafe: false,
    healthFactorAfter: null as number | null,
    removeUsd: Math.round((currentCollateralUsd * Math.max(0, percent)) / 100),
    afterCollateralUsd: currentCollateralUsd,
    safePercent: 0,
    warningMessage: position && percent > 0 ? TRANSACTIONS_UNAVAILABLE : (null as string | null),
  }
}

export function buildDepositPreviewModel(
  _state: BorrowSystemState,
  _walletId: string,
  _marketId: string,
  amountUsd: number,
) {
  return {
    isEmpty: amountUsd <= 0,
    isValid: false,
    borrowCapacityUsd: 0,
    borrowPowerDeltaUsd: 0,
    collateralValueUsd: 0,
    healthFactor: null as number | null,
    warningMessage: amountUsd > 0 ? TRANSACTIONS_UNAVAILABLE : (null as string | null),
  }
}
