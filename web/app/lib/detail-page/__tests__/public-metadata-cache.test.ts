import { afterEach, expect, it, vi } from "vitest"
import { createPublicMetadataCache, fetchWithReadDeadline, publicMetadataKey } from "../public-metadata-cache"
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
})
it("deduplicates 100 reads and refreshes after expiry or invalidation", async () => {
  vi.useFakeTimers()
  const cache = createPublicMetadataCache(60)
  const read = vi.fn(async () => "metadata")
  expect(await Promise.all(Array.from({ length: 100 }, () => cache.get("a", read)))).toHaveLength(100)
  expect(read).toHaveBeenCalledTimes(1)
  vi.advanceTimersByTime(61)
  await cache.get("a", read)
  cache.clear()
  await cache.get("a", read)
  expect(read).toHaveBeenCalledTimes(3)
})
it("retries failures and bounds entries", async () => {
  const cache = createPublicMetadataCache(60_000, 1)
  await expect(
    cache.get("a", async () => {
      throw Error("offline")
    }),
  ).rejects.toThrow("offline")
  expect(await cache.get("a", async () => 1)).toBe(1)
  await cache.get("b", async () => 2)
  expect(await cache.get("a", async () => 3)).toBe(3)
})
it("isolates deployments and revisions", () => {
  vi.stubEnv("NEXT_PUBLIC_CONVEX_URL", "https://first.convex.cloud")
  const first = publicMetadataKey("content", "usdc")
  vi.stubEnv("NEXT_PUBLIC_CONVEX_URL", "https://second.convex.cloud")
  expect(publicMetadataKey("content", "usdc")).not.toBe(first)
})
it("aborts the actual transport and preserves caller cancellation", async () => {
  vi.useFakeTimers()
  vi.stubGlobal(
    "fetch",
    vi.fn(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init.signal.addEventListener("abort", () => reject(init.signal.reason))
        }),
    ),
  )
  const controller = new AbortController()
  const pending = fetchWithReadDeadline("https://example.test", { signal: controller.signal })
  controller.abort()
  await expect(pending).rejects.toThrow()
  expect(vi.mocked(fetch).mock.calls[0][1]?.signal).toBeInstanceOf(AbortSignal)
})
