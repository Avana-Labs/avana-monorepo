import type { RewardsSessionState } from "./contracts"
import { safeReadParsed, safeRemoveItem, safeSetItem } from "@/app/lib/safe-local-storage"
import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"

const REWARDS_STATE_PREFIX = `avana.rewards.session.${SESSION_CACHE_VERSION}`

function stateKey(walletId: string) {
  return `${REWARDS_STATE_PREFIX}:${walletId}`
}

function parseSeedOrDefault(sessionSeed: string): RewardsSessionState {
  try {
    return JSON.parse(sessionSeed) as RewardsSessionState
  } catch {
    return buildDefaultRewardsSessionState()
  }
}

export function buildDefaultRewardsSessionState(): RewardsSessionState {
  return {
    events: [],
    claims: [],
    referralProfiles: {},
    relationships: [],
    firstLoginAt: 0,
    favoriteMarketIds: [],
  }
}

export function readRewardsSessionState(walletId: string, sessionSeed: string): RewardsSessionState {
  if (typeof window === "undefined") {
    return parseSeedOrDefault(sessionSeed)
  }

  return safeReadParsed(
    stateKey(walletId),
    (raw) => JSON.parse(raw) as RewardsSessionState,
    () => parseSeedOrDefault(sessionSeed),
  )
}

export function writeRewardsSessionState(walletId: string, state: RewardsSessionState) {
  safeSetItem(stateKey(walletId), JSON.stringify(state))
}

export function clearRewardsSessionState(walletId: string) {
  safeRemoveItem(stateKey(walletId))
}

export function buildDefaultRewardsSessionSeed() {
  return JSON.stringify(buildDefaultRewardsSessionState())
}
