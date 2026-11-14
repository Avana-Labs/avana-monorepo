import type { MultiplySystemState } from "@/app/lib/multiply-engine"

export function serializeMultiplySystemState(state: MultiplySystemState) {
  return JSON.stringify(state)
}

export function deserializeMultiplySystemState(serialized: string): MultiplySystemState {
  return JSON.parse(serialized) as MultiplySystemState
}
