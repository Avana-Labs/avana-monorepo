import type { MultiplySystemState } from "@/app/lib/multiply-engine"
import { deserializeMultiplySystemState, serializeMultiplySystemState } from "./codec"
import type { MultiplyTransactionHistoryItem, MultiplyTransactionResult } from "./contracts"
import { notifyMultiplySessionChanged } from "./session-sync"
import { safeReadParsed, safeRemoveItem, safeSetItem } from "@/app/lib/safe-local-storage"
import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"

const STORAGE_PREFIX = `avana.multiply.session.${SESSION_CACHE_VERSION}`
const META_STORAGE_PREFIX = `avana.multiply.session.meta.${SESSION_CACHE_VERSION}`

type MultiplySessionMetadata = {
  transactionHistory: MultiplyTransactionHistoryItem[]
  receipts: MultiplyTransactionResult[]
}

function multiplySessionStorageKey(walletId: string) {
  return `${STORAGE_PREFIX}:${walletId}`
}

function multiplySessionMetadataKey(walletId: string) {
  return `${META_STORAGE_PREFIX}:${walletId}`
}

export function readMultiplySessionState(walletId: string, seed: string): MultiplySystemState {
  return safeReadParsed(
    multiplySessionStorageKey(walletId),
    (raw) => deserializeMultiplySystemState(raw),
    () => deserializeMultiplySystemState(seed),
  )
}

export function writeMultiplySessionState(walletId: string, state: MultiplySystemState) {
  if (typeof window === "undefined") return
  safeSetItem(multiplySessionStorageKey(walletId), serializeMultiplySystemState(state))
  notifyMultiplySessionChanged(walletId)
}

export function readMultiplySessionMetadata(walletId: string): MultiplySessionMetadata {
  return safeReadParsed<MultiplySessionMetadata>(
    multiplySessionMetadataKey(walletId),
    (raw) => JSON.parse(raw) as MultiplySessionMetadata,
    () => ({ transactionHistory: [], receipts: [] }),
  )
}

export function writeMultiplySessionMetadata(walletId: string, metadata: MultiplySessionMetadata) {
  if (typeof window === "undefined") return
  safeSetItem(multiplySessionMetadataKey(walletId), JSON.stringify(metadata))
  notifyMultiplySessionChanged(walletId)
}

export function clearMultiplySessionState(walletId: string) {
  safeRemoveItem(multiplySessionStorageKey(walletId))
  safeRemoveItem(multiplySessionMetadataKey(walletId))
}
