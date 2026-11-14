/**
 * Provider-level optimistic-concurrency tracking for sandbox writes (see
 * avana-sessions-provider's ConvexAvanaSessionsProvider).
 *
 * The server (recordTransaction) bumps a `revision` on every position write and rejects a
 * write whose `expectedRevision` is stale (STALE_WRITE) instead of silently clobbering a
 * concurrent one. To send the RIGHT expectedRevision, the client must echo the revision its
 * local engine state was actually HYDRATED to — not the latest server value (which would
 * always match and defeat the guard). This module tracks that per (product, market):
 *
 *   - captureHydratedRevisions: called ONLY when a getSessionState emit is actually applied
 *     to the engine state (respecting the H19 hydration guard), so the map mirrors what the
 *     local engine is based on.
 *   - withExpectedRevision: attaches the tracked revision to a recordTransaction arg set.
 *   - advanceRevisionOnSuccess: optimistically bumps after a successful write so a rapid
 *     same-tab follow-up (before the next re-emit lands) isn't falsely rejected. The next
 *     applied hydration overwrites the map with authoritative values, so any drift is
 *     transient and self-correcting.
 */

export type PositionRevisionSummary = { product: string; marketSlug?: string | null; revision?: number | null }

export function positionRevisionKey(product: string, marketSlug: string | null | undefined): string | null {
  return marketSlug ? `${product}:${marketSlug}` : null
}

/** Rebuild the revision map from an applied hydration snapshot (the authoritative full set). */
export function captureHydratedRevisions(
  map: Map<string, number>,
  positions: readonly PositionRevisionSummary[],
): void {
  map.clear()
  for (const position of positions) {
    const key = positionRevisionKey(position.product, position.marketSlug)
    if (key) map.set(key, position.revision ?? 0)
  }
}

/** Attach expectedRevision to a recordTransaction arg set from the tracked map (if known). */
export function withExpectedRevision<T extends { marketSlug?: string; position?: { marketSlug?: string } }>(
  args: T,
  product: string,
  map: Map<string, number>,
): { args: T; key: string | null } {
  const key = positionRevisionKey(product, args.position?.marketSlug ?? args.marketSlug)
  const expectedRevision = key ? map.get(key) : undefined
  return { args: expectedRevision != null ? { ...args, expectedRevision } : args, key }
}

/**
 * After a successful, non-idempotent write, advance the tracked revision by one (or seed it
 * to 0 for a newly-created position) so an immediate same-tab follow-up write sends the
 * correct expectedRevision. Idempotent replays leave the server revision unchanged, so they
 * must NOT advance it.
 */
export function advanceRevisionOnSuccess(map: Map<string, number>, key: string | null, idempotent: boolean): void {
  if (!key || idempotent) return
  const prev = map.get(key)
  map.set(key, prev == null ? 0 : prev + 1)
}

/**
 * Seed the tracked revision directly from a recordTransaction receipt's authoritative
 * `revision`. Preferred over advanceRevisionOnSuccess because it works for BOTH fresh writes
 * and idempotent replays: an idempotent CREATE replay (original response lost) leaves the map
 * empty, and the client-side +1 inference skips idempotent results — so the next write sent no
 * expectedRevision and the server rejected it with REVISION_REQUIRED (M-12). Seeding from the
 * server value keeps the map correct in every case.
 */
export function seedRevisionFromReceipt(
  map: Map<string, number>,
  key: string | null,
  revision: number | null | undefined,
): void {
  if (!key || revision == null) return
  map.set(key, revision)
}
