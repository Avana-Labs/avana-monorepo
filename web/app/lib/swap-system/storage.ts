import { safeReadParsed, safeSetItem } from "@/app/lib/safe-local-storage"
import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"
import type { SwapSystemState } from "./transaction-adapter"

type PersistedSwapSession = SwapSystemState & { revision: number }

const SWAP_STATE_PREFIX = `avana.swap.session.${SESSION_CACHE_VERSION}`

export function swapSessionStorageKey(walletId: string) {
  return `${SWAP_STATE_PREFIX}:${walletId}`
}

function stateKey(walletId: string) {
  return swapSessionStorageKey(walletId)
}

function parseSwapState(raw: string, fallback: SwapSystemState): PersistedSwapSession {
  const parsed = JSON.parse(raw) as Partial<PersistedSwapSession>
  return {
    balances: Array.isArray(parsed.balances) ? parsed.balances : fallback.balances,
    allowances: parsed.allowances && typeof parsed.allowances === "object" ? parsed.allowances : {},
    transactions: Array.isArray(parsed.transactions) ? parsed.transactions : [],
    revision: typeof parsed.revision === "number" && Number.isFinite(parsed.revision) ? parsed.revision : 0,
  }
}

export function mergeSwapSessionStates(
  base: PersistedSwapSession,
  incoming: PersistedSwapSession,
): PersistedSwapSession {
  const winner = incoming.revision >= base.revision ? incoming : base
  const loser = winner === incoming ? base : incoming
  const transactionsById = new Map(loser.transactions.map((tx) => [tx.id, tx]))
  for (const tx of winner.transactions) transactionsById.set(tx.id, tx)
  return {
    balances: winner.balances,
    allowances: { ...loser.allowances, ...winner.allowances },
    transactions: [...transactionsById.values()].sort((a, b) => a.createdAt - b.createdAt),
    revision: Math.max(base.revision, incoming.revision),
  }
}

export function readSwapSessionState(walletId: string, fallback: SwapSystemState): PersistedSwapSession {
  return safeReadParsed(
    stateKey(walletId),
    (raw) => parseSwapState(raw, fallback),
    () => ({ ...fallback, revision: 0 }),
  )
}

export function writeSwapSessionState(
  walletId: string,
  state: SwapSystemState,
  expectedRevision?: number,
): PersistedSwapSession {
  const current = readSwapSessionState(walletId, state)
  const nextRevision = current.revision + 1
  const payload: PersistedSwapSession = { ...state, revision: nextRevision }

  if (expectedRevision !== undefined && expectedRevision !== current.revision) {
    const merged = mergeSwapSessionStates(current, { ...state, revision: expectedRevision + 1 })
    safeSetItem(stateKey(walletId), JSON.stringify(merged))
    notifySwapSessionUpdated(walletId)
    return merged
  }

  safeSetItem(stateKey(walletId), JSON.stringify(payload))
  notifySwapSessionUpdated(walletId)
  return payload
}

function notifySwapSessionUpdated(walletId: string) {
  if (typeof window === "undefined") return
  window.dispatchEvent(new CustomEvent("avana:swap-session-updated", { detail: { walletId } }))
}
