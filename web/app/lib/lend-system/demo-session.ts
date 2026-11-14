import { buildDefaultLendSessionSeed } from "./storage"
import { serializeLendSystemState } from "./codec"
import { buildMockLendSystemState } from "./mock"

export function buildLendSessionSeed(walletId: string) {
  return buildDefaultLendSessionSeed(walletId)
}

export function buildConvexLendSessionSeed(walletId: string) {
  const state = buildMockLendSystemState(walletId)
  return serializeLendSystemState({
    ...state,
    walletBalances: { [walletId]: {} },
    positions: {},
    transactions: [],
  })
}
