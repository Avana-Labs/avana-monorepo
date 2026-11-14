// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/** Bounded deterministic jitter keeps subjects from retrying on the same tick. */
export function queueRetryDelay(attempt: number, key: string): number {
  let hash = 0
  for (const char of key) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  const base = Math.min(25_000, 2_500 * 2 ** Math.min(Math.max(0, attempt), 4))
  return Math.round(base * (1 + (hash % 201) / 1000))
}
