/** Shared deterministic helpers for stable mock data and charts. */

/**
 * The sandbox's canonical "current time". Every mock/chart anchors its date range
 * to this one clock so ranges stay consistent across surfaces (list hero, detail
 * charts, history) instead of each module drifting to its own hardcoded month.
 * Matches the borrow/lend/multiply system-state `now` (Jun 19, 2026).
 */
export const SANDBOX_NOW = Date.UTC(2026, 5, 19)

export function hashString(value: string) {
  let hash = 2166136261

  for (let index = 0; index < value.length; index++) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }

  return hash >>> 0
}

export function createSeededRandom(seed: string) {
  let state = hashString(seed) || 1

  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let result = Math.imul(state ^ (state >>> 15), 1 | state)
    result ^= result + Math.imul(result ^ (result >>> 7), 61 | result)
    return ((result ^ (result >>> 14)) >>> 0) / 4294967296
  }
}

export function getDeterministicAmount(seed: string, min: number, max: number) {
  return min + (hashString(seed) % (max - min + 1))
}
