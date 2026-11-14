const walletQueues = new Map<string, Promise<unknown>>()

/**
 * Serialize Convex rewards snapshots for one wallet. Web Locks coordinates
 * browser tabs; the promise queue covers browsers without Web Locks and
 * multiple providers mounted in the same document.
 */
export async function withRewardsPersistenceLock<T>(walletId: string, task: () => Promise<T>): Promise<T> {
  const previous = walletQueues.get(walletId) ?? Promise.resolve()
  const run = previous
    .catch(() => undefined)
    .then(async () => {
      if (typeof navigator !== "undefined" && navigator.locks) {
        return navigator.locks.request(`avana:rewards:${walletId.toLowerCase()}`, task)
      }
      return task()
    })
  walletQueues.set(walletId, run)
  try {
    return await run
  } finally {
    if (walletQueues.get(walletId) === run) walletQueues.delete(walletId)
  }
}
