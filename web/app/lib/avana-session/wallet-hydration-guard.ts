/**
 * Guard for the reactive WalletHydrator.
 *
 * `getSessionState` re-emits on every write and each emit fully REPLACES the local
 * position/history set. A snapshot that predates a just-submitted optimistic edit would clobber
 * it, so a snapshot is only safe to apply once it contains every optimistic intent the client
 * knows about. Intent-keyed equivalent of the borrow session's `persistedAt` cross-tab guard.
 */

/** Snapshot shape we need from `getSessionState` — just the intent ids of its rows. */
type HydrationSnapshot = {
  transactions: ReadonlyArray<{ intentId?: string | null }>
}

/**
 * How long an optimistic intent may gate hydration before it is assumed never-landing. A write
 * round-trips well under a second, so anything still missing after this window is treated as
 * rejected/lost — bounding a poison intent to a brief flicker instead of a permanent freeze.
 */
export const HYDRATION_GATE_TTL_MS = 30_000

/** Local history item shape the gate needs: its intent id, status, and submit time. */
type PendingHydrationItem = { intentId: string; status: string; timestamp: number }

/**
 * The local intent ids that should gate hydration: recent, non-failed optimistic writes. Failed
 * actions keep no durable server row and intents older than `ttlMs` may never land, so neither
 * may gate — otherwise they freeze the WalletHydrator permanently.
 */
export function pendingHydrationIntentIds(
  items: Iterable<PendingHydrationItem>,
  now: number,
  ttlMs: number = HYDRATION_GATE_TTL_MS,
): Set<string> {
  const pending = new Set<string>()
  for (const item of items) {
    if (item.status !== "failed" && now - item.timestamp < ttlMs) pending.add(item.intentId)
  }
  return pending
}

/**
 * Decide whether an incoming Convex snapshot is safe to hydrate from.
 *
 * @param snapshot           the re-emitted session state (undefined while loading)
 * @param localIntentIds     intent ids of the client's current (incl. optimistic) writes
 * @returns true when every local intent is reflected in the snapshot (safe to apply)
 */
export function shouldApplyHydration(
  snapshot: HydrationSnapshot | undefined | null,
  localIntentIds: Iterable<string>,
): boolean {
  if (!snapshot) return false
  const remote = new Set<string>()
  for (const tx of snapshot.transactions) {
    if (tx.intentId) remote.add(tx.intentId)
  }
  for (const intentId of localIntentIds) {
    if (!remote.has(intentId)) return false // an in-flight edit is not yet in this emit → stale
  }
  return true
}
