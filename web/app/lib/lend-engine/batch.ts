import { applyLendAction } from "./actions"
import type { LendAction, LendSystemState } from "./types"

export function applyLendActions(state: LendSystemState, actions: LendAction[]) {
  const ordered = actions
    .map((action, index) => ({
      action,
      index,
      at: action.at ?? state.now,
    }))
    .sort((left, right) => left.at - right.at || left.index - right.index)

  return ordered.reduce((current, entry, index) => {
    try {
      const positionId =
        entry.action.type === "withdraw"
          ? entry.action.positionId
          : entry.action.type === "deposit"
            ? `${entry.action.walletId}:${entry.action.marketId}`
            : `${entry.action.walletId}:rewards`
      return applyLendAction(current, entry.action, {
        positionId,
        transactionId: `batch-${index}`,
      })
    } catch {
      return current
    }
  }, state)
}
