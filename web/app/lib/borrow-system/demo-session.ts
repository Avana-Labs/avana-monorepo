import { getDefaultWalletProfileId } from "@/app/lib/data/wallet/profiles"
import { serializeBorrowSystemState } from "./codec"
import { buildMockBorrowSystemState } from "./mock"

function getBorrowSessionWalletId() {
  return getDefaultWalletProfileId()
}

export function buildBorrowSessionSeed(walletId = getBorrowSessionWalletId()) {
  return serializeBorrowSystemState(buildMockBorrowSystemState(walletId))
}

export function buildConvexBorrowSessionSeed(walletId: string) {
  const state = buildMockBorrowSystemState(walletId)
  return serializeBorrowSystemState({
    ...state,
    accounts: {
      [walletId]: {
        walletId,
        walletBalanceUsd6: 0n,
        walletLpBalancesUsd6: {},
        interestSettledUsd6: 0n,
        lastUpdatedAt: state.now,
        collateralPositions: [],
        debtPositions: [],
        rewardPositions: [],
      },
    },
    transactions: [],
  })
}
