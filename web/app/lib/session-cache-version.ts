/**
 * Single source of truth for the sandbox session localStorage cache version.
 *
 * Every per-product session storage prefix (borrow / lend / multiply / swap /
 * rewards) embeds this segment. Bump it whenever a price baseline or an engine
 * formula changes in a way that makes previously persisted session state stale —
 * old keys are simply no longer read, so the next load rebuilds from the current
 * baseline instead of silently surfacing yesterday's numbers.
 *
 * History:
 *  - v1: original sandbox sessions.
 *  - v2: single sandbox price baseline (ETH $1934, not $3500) + downstream
 *        engine/read-model corrections. v1 sessions cached the old prices.
 *  - v3: concise pool venue label ("Uniswap v2 LPs", not "Uniswap ·
 *        Constant-product LP tokens"). v2 sessions persisted the old venue string.
 */
export const SESSION_CACHE_VERSION = "v3"
