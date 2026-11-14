import { expect, it, vi } from "vitest"
import { createCatalogPageSources } from "../catalog-page-source"
it("serves 100 mock catalog requests without contacting the snapshot provider", async () => {
  const fetchSnapshots = vi.fn(async () => {
    throw new Error("Network forbidden")
  })
  const sources = createCatalogPageSources({
    product: "borrow",
    buildBaselineState: () => ({ value: 1 }),
    fetchSnapshots,
    mergeSnapshots: (s) => s,
    readPageData: (s) => s,
  })
  const results = await Promise.all(Array.from({ length: 100 }, () => sources.mockSource.getPageData()))
  expect(results.every((r) => r.data.value === 1)).toBe(true)
  expect(fetchSnapshots).not.toHaveBeenCalled()
  await expect(sources.liveSource.getPageData()).rejects.toThrow("Network forbidden")
})
it("requires live snapshots and merges a successful live response", async () => {
  const fetchSnapshots = vi.fn<() => Promise<number[]>>().mockResolvedValueOnce([]).mockResolvedValueOnce([5])
  const sources = createCatalogPageSources({
    product: "lend",
    buildBaselineState: () => 1,
    fetchSnapshots,
    mergeSnapshots: (_, rows) => rows[0]!,
    readPageData: (s) => s,
  })
  await expect(sources.liveSource.getPageData()).rejects.toThrow(/no Lend market snapshots/)
  expect((await sources.liveSource.getPageData()).data).toBe(5)
})
