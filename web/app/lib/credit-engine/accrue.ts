import type { BorrowSystemState } from "./types"
import { accrueLinearIndex } from "./units"

export function accrueBorrowSystemState(state: BorrowSystemState, nextNow: number): BorrowSystemState {
  if (nextNow <= state.now) return state

  const elapsedSeconds = BigInt(Math.floor((nextNow - state.now) / 1000))
  if (elapsedSeconds <= 0n) return state

  const markets: BorrowSystemState["markets"] = {}
  for (const [marketId, market] of Object.entries(state.markets)) {
    markets[marketId] = {
      ...market,
      snapshot: {
        ...market.snapshot,
        supplyIndexRay: accrueLinearIndex(market.snapshot.supplyIndexRay, market.snapshot.feeApyWad, elapsedSeconds),
      },
    }
  }

  const accounts: BorrowSystemState["accounts"] = {}
  for (const [walletId, account] of Object.entries(state.accounts)) {
    accounts[walletId] = {
      ...account,
      lastUpdatedAt: nextNow,
      debtPositions: account.debtPositions.map((position) => ({
        ...position,
        debtIndexRay: accrueLinearIndex(position.debtIndexRay, position.borrowRateWad, elapsedSeconds),
      })),
    }
  }

  return {
    ...state,
    now: nextNow,
    markets,
    accounts,
  }
}
