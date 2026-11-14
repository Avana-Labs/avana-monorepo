import type { LendSystemState } from "@/app/lib/lend-engine"

export function serializeLendSystemState(state: LendSystemState) {
  return JSON.stringify(state)
}

export function deserializeLendSystemState(serialized: string): LendSystemState {
  const parsed = JSON.parse(serialized) as Partial<LendSystemState>
  return {
    now: parsed.now ?? Date.now(),
    markets: parsed.markets ?? {},
    positions: parsed.positions ?? {},
    walletBalances: parsed.walletBalances ?? {},
    transactions: parsed.transactions ?? [],
  }
}
