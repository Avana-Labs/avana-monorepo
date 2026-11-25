/** Bounded warm-instance cache for public editorial metadata only. */
export function createPublicMetadataCache(ttlMs = 60_000, maxEntries = 256) {
  const entries = new Map<string, { expires: number; value: Promise<unknown> }>()
  return {
    clear: () => entries.clear(),
    async get<T>(key: string, read: () => Promise<T>): Promise<T> {
      const current = entries.get(key)
      if (current && current.expires > Date.now()) return current.value as Promise<T>
      entries.delete(key)
      if (entries.size >= maxEntries) entries.delete(entries.keys().next().value!)
      const entry = { expires: Date.now() + ttlMs, value: Promise.resolve().then(read) }
      entries.set(key, entry)
      try {
        return (await entry.value) as T
      } catch (error) {
        if (entries.get(key) === entry) entries.delete(key)
        throw error
      }
    },
  }
}

export const publicMetadataCache = createPublicMetadataCache()
export function publicMetadataKey(kind: string, slug: string) {
  return JSON.stringify([process.env.NEXT_PUBLIC_CONVEX_URL, process.env.AVANA_PUBLIC_METADATA_VERSION, kind, slug])
}

export const fetchWithReadDeadline: typeof fetch = (input, init) =>
  fetch(input, {
    ...init,
    signal: init?.signal ? AbortSignal.any([init.signal, AbortSignal.timeout(8_000)]) : AbortSignal.timeout(8_000),
  })
