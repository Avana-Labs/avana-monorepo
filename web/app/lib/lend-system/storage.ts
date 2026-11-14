import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"

const LEND_STATE_PREFIX = `avana.lend.session.${SESSION_CACHE_VERSION}`
const LEND_META_PREFIX = `avana.lend.session.meta.${SESSION_CACHE_VERSION}`

import { deserializeLendSystemState, serializeLendSystemState } from "./codec"
import type { LendTransactionHistoryItem, LendTransactionResult } from "./contracts"
import { buildDemoLendSystemState } from "./mock"
import { safeReadParsed, safeRemoveItem, safeSetItem } from "@/app/lib/safe-local-storage"

type LendSessionMetadata = {
  transactionHistory: LendTransactionHistoryItem[]
  receipts: LendTransactionResult[]
}

function stateKey(walletId: string) {
  return `${LEND_STATE_PREFIX}:${walletId}`
}

function metaKey(walletId: string) {
  return `${LEND_META_PREFIX}:${walletId}`
}

export function readLendSessionState(walletId: string, sessionSeed: string) {
  return safeReadParsed(
    stateKey(walletId),
    (raw) => deserializeLendSystemState(raw),
    () => deserializeLendSystemState(sessionSeed),
  )
}

export function writeLendSessionState(walletId: string, state: ReturnType<typeof deserializeLendSystemState>) {
  safeSetItem(stateKey(walletId), serializeLendSystemState(state))
}

export function readLendSessionMetadata(walletId: string): LendSessionMetadata {
  return safeReadParsed<LendSessionMetadata>(
    metaKey(walletId),
    (raw) => JSON.parse(raw) as LendSessionMetadata,
    () => ({ transactionHistory: [], receipts: [] }),
  )
}

export function writeLendSessionMetadata(walletId: string, metadata: LendSessionMetadata) {
  safeSetItem(metaKey(walletId), JSON.stringify(metadata))
}

export function clearLendSessionState(walletId: string) {
  safeRemoveItem(stateKey(walletId))
  safeRemoveItem(metaKey(walletId))
}

export function buildDefaultLendSessionSeed(walletId: string) {
  return serializeLendSystemState(buildDemoLendSystemState(walletId))
}
