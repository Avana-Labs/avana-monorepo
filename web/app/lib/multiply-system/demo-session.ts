import { getDefaultWalletProfileId } from "@/app/lib/data/wallet/profiles"
import { serializeMultiplySystemState } from "./codec"
import { buildMockMultiplySystemState } from "./mock"

function getMultiplySessionWalletId() {
  return getDefaultWalletProfileId()
}

export function buildMultiplySessionSeed(walletId = getMultiplySessionWalletId()) {
  return serializeMultiplySystemState(buildMockMultiplySystemState(walletId))
}

export function buildConvexMultiplySessionSeed(walletId: string) {
  return serializeMultiplySystemState(buildMockMultiplySystemState(walletId))
}
