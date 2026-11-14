import { applyBorrowAction } from "./actions"
import type { BorrowAction, BorrowSystemState } from "./types"

type BorrowValidationResult = {
  actionType: BorrowAction["type"]
  allowed: boolean
  validationErrors: string[]
}

export function validateAction(state: BorrowSystemState, action: BorrowAction): BorrowValidationResult {
  try {
    applyBorrowAction(state, action)
    return {
      actionType: action.type,
      allowed: true,
      validationErrors: [],
    }
  } catch (error) {
    return {
      actionType: action.type,
      allowed: false,
      validationErrors: [error instanceof Error ? error.message : String(error)],
    }
  }
}
