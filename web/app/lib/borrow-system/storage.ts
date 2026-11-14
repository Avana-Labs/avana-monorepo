import type { BorrowSystemState } from "@/app/lib/credit-engine"
import type { SyntheticTransactionReceipt, TransactionHistoryItem } from "@/app/lib/borrow-system/contracts"
import {
  deserializeBorrowSystemState,
  deserializeBorrowValue,
  serializeBorrowSystemState,
  serializeBorrowValue,
} from "@/app/lib/borrow-system/codec"
import { safeReadParsed, safeRemoveItem, safeSetItem } from "@/app/lib/safe-local-storage"
import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"

const STORAGE_PREFIX = `avana.borrow.session.${SESSION_CACHE_VERSION}`
const META_STORAGE_PREFIX = `avana.borrow.session.meta.${SESSION_CACHE_VERSION}`

type BorrowSessionMetadata = {
  transactionHistory: TransactionHistoryItem[]
  receipts: SyntheticTransactionReceipt[]
  /** Monotonic write timestamp used to reject stale cross-tab overwrites. */
  persistedAt?: number
}

function borrowSessionStorageKey(walletId: string) {
  return `${STORAGE_PREFIX}:${walletId}`
}

function borrowSessionMetadataKey(walletId: string) {
  return `${META_STORAGE_PREFIX}:${walletId}`
}

export function readBorrowSessionState(walletId: string, seed: string): BorrowSystemState {
  if (typeof window === "undefined") {
    return deserializeBorrowSystemState(seed)
  }

  return safeReadParsed(
    borrowSessionStorageKey(walletId),
    (raw) => deserializeBorrowSystemState(raw),
    () => deserializeBorrowSystemState(seed),
  )
}

export function writeBorrowSessionState(walletId: string, state: BorrowSystemState) {
  safeSetItem(borrowSessionStorageKey(walletId), serializeBorrowSystemState(state))
}

export function readBorrowSessionMetadata(walletId: string): BorrowSessionMetadata {
  return safeReadParsed<BorrowSessionMetadata>(
    borrowSessionMetadataKey(walletId),
    (raw) => deserializeBorrowValue<BorrowSessionMetadata>(raw),
    () => ({ transactionHistory: [], receipts: [] }),
  )
}

export function writeBorrowSessionMetadata(walletId: string, metadata: BorrowSessionMetadata) {
  safeSetItem(borrowSessionMetadataKey(walletId), serializeBorrowValue(metadata))
}

export function clearBorrowSessionState(walletId: string) {
  safeRemoveItem(borrowSessionStorageKey(walletId))
  safeRemoveItem(borrowSessionMetadataKey(walletId))
}
