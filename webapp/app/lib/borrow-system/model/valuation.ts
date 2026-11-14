import { repriceDebtValueUsd6 } from "./borrowed-asset-valuation"
import { TOKEN_SCALE, mulDiv, sharesToAssets } from "./units"
import type {
  BorrowAccountState,
  BorrowAssetRecord,
  BorrowMarketRecord,
  BorrowSystemState,
  UserCollateralPosition,
  UserDebtPosition,
} from "./types"

function tokenAmountToUsd6(tokenAmount: bigint, priceUsd6: bigint) {
  return mulDiv(tokenAmount, priceUsd6, TOKEN_SCALE)
}

function currentCollateralTokenAmount(position: UserCollateralPosition, market: BorrowMarketRecord) {
  return sharesToAssets(position.collateralShares, market.snapshot.supplyIndexRay)
}

export function currentCollateralValueUsd6(position: UserCollateralPosition, market: BorrowMarketRecord) {
  return tokenAmountToUsd6(currentCollateralTokenAmount(position, market), market.snapshot.lpTokenPriceUsd6)
}

export function collateralInterestEarnedUsd6(position: UserCollateralPosition, market: BorrowMarketRecord) {
  const currentAmount = currentCollateralTokenAmount(position, market)
  const earnedAmount =
    currentAmount > position.principalTokenAmount ? currentAmount - position.principalTokenAmount : 0n
  return tokenAmountToUsd6(earnedAmount, market.snapshot.lpTokenPriceUsd6)
}

/**
 * Current USD6 debt for a position: fixed-USD (principal + accrued interest) unless
 * `currentPriceUsd6` is supplied, in which case it is repriced to that spot price.
 */
export function currentDebtValueUsd6(position: UserDebtPosition, currentPriceUsd6?: bigint) {
  const atBorrow = sharesToAssets(position.debtSharesUsd6, position.debtIndexRay)
  return repriceDebtValueUsd6(atBorrow, position.priceAtBorrowUsd6, currentPriceUsd6)
}

export function debtInterestOwedUsd6(position: UserDebtPosition) {
  const currentDebt = currentDebtValueUsd6(position)
  return currentDebt > position.principalBorrowedUsd6 ? currentDebt - position.principalBorrowedUsd6 : 0n
}

export function totalCollateralValueUsd6(account: BorrowAccountState, markets: Record<string, BorrowMarketRecord>) {
  return account.collateralPositions.reduce((sum, position) => {
    const market = markets[position.marketId]
    if (!market || !position.collateralEnabled) return sum
    return sum + currentCollateralValueUsd6(position, market)
  }, 0n)
}

export function totalInterestEarnedUsd6(account: BorrowAccountState, markets: Record<string, BorrowMarketRecord>) {
  return account.collateralPositions.reduce((sum, position) => {
    const market = markets[position.marketId]
    if (!market || !position.collateralEnabled) return sum
    return sum + collateralInterestEarnedUsd6(position, market)
  }, 0n)
}

/**
 * Σ over borrowed single-token positions. Pass `assets` to reprice each position to its
 * asset's current spot price. Debt is never LP-valued.
 */
export function totalDebtValueUsd6(account: BorrowAccountState, assets?: Record<string, BorrowAssetRecord>) {
  return account.debtPositions.reduce((sum, position) => {
    const currentPriceUsd6 = assets?.[position.assetId]?.snapshot.priceUsd6
    return sum + currentDebtValueUsd6(position, currentPriceUsd6)
  }, 0n)
}

export function totalInterestOwedUsd6(account: BorrowAccountState) {
  return account.debtPositions.reduce((sum, position) => sum + debtInterestOwedUsd6(position), 0n)
}

function resolveAccount(state: BorrowSystemState, walletId: string) {
  return state.accounts[walletId]
}

export function calculateCollateralValueUsd6(state: BorrowSystemState, walletId: string) {
  const account = resolveAccount(state, walletId)
  if (!account) throw new Error(`Unknown wallet ${walletId}`)
  return totalCollateralValueUsd6(account, state.markets)
}
