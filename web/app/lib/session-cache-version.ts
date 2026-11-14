/**
 * Single source of truth for the session localStorage cache version.
 *
 * Every per-product session storage prefix (borrow / lend / swap) embeds this segment. Bump it whenever a price baseline or an engine
 * formula changes in a way that makes previously persisted session state stale —
 * old keys are simply no longer read, so the next load rebuilds from the current
 * baseline instead of silently surfacing yesterday's numbers.
 *
 * History:
 *  - v4: sessions start empty and read markets from services/convex; earlier keys held
 *        prototype data.
 */
export const SESSION_CACHE_VERSION = "v4"
