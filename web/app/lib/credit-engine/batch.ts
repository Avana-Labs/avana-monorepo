import { applyBorrowAction } from "./actions"
import type { BorrowAction, BorrowSystemState } from "./types"

export function applyBorrowActions(state: BorrowSystemState, actions: BorrowAction[]) {
  const ordered = actions
    .map((action, index) => ({
      action,
      index,
      at: action.at ?? state.now,
    }))
    .sort((left, right) => left.at - right.at || left.index - right.index)

  return ordered.reduce((current, entry) => applyBorrowAction(current, entry.action), state)
}
