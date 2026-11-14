import { applyMultiplyAction } from "./actions"
import type { MultiplyAction, MultiplySystemState } from "./types"

export function applyMultiplyActions(state: MultiplySystemState, actions: MultiplyAction[]) {
  const ordered = actions
    .map((action, index) => ({
      action,
      index,
      at: action.at ?? state.now,
    }))
    .sort((left, right) => left.at - right.at || left.index - right.index)

  return ordered.reduce((current, entry) => {
    try {
      return applyMultiplyAction(current, entry.action)
    } catch {
      return current
    }
  }, state)
}
