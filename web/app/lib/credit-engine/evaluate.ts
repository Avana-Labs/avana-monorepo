import { applyBorrowAction } from "./actions"
import type { BorrowAction, BorrowSystemState } from "./types"

function cloneState(state: BorrowSystemState): BorrowSystemState {
  return structuredClone(state)
}

export function evaluateBorrowAction(
  state: BorrowSystemState,
  action: BorrowAction,
  mode: "dry-run" | "commit" = "commit",
): BorrowSystemState {
  const source = mode === "dry-run" ? cloneState(state) : state
  return applyBorrowAction(source, action)
}
