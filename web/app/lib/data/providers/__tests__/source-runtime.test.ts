import { describe, expect, it } from "vitest"
import {
  DataSourceError,
  createDataSourceAdapter,
  dedupeByStableId,
  executeSourceLoad,
  normalizeDataSourceError,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"

describe("source runtime", () => {
  it("falls back to a secondary adapter for unsupported live sources", async () => {
    const liveAdapter = createDataSourceAdapter({
      id: "portfolio-live-test",
      label: "Portfolio live test source",
      mode: "live",
    })
    const mockAdapter = createDataSourceAdapter({
      id: "portfolio-mock-test",
      label: "Portfolio mock test source",
      mode: "mock",
    })

    const result = await executeSourceLoad({
      primary: {
        adapter: liveAdapter,
        async load(): Promise<DataSourceResponse<{ value: number }>> {
          throw new DataSourceError({
            code: "unsupported",
            sourceId: liveAdapter.id,
            operation: "load",
            message: `Live data source is not implemented for ${liveAdapter.label}.`,
            retryable: false,
          })
        },
      },
      fallback: {
        adapter: mockAdapter,
        async load(): Promise<DataSourceResponse<{ value: number }>> {
          return {
            data: { value: 42 },
            fetchedAt: "2026-06-17T00:00:00.000Z",
          }
        },
      },
      operation: "load",
      load: (source) => source.load(),
    })

    expect(result.data.value).toBe(42)
  })

  it("normalizes source failures into a common error model", () => {
    const adapter = createDataSourceAdapter({
      id: "borrow-live-test",
      label: "Borrow live test source",
      mode: "live",
    })

    const error = normalizeDataSourceError(new Error("boom"), adapter, "getBorrowPageData")

    expect(error.name).toBe("DataSourceError")
    expect(error.sourceId).toBe("borrow-live-test")
    expect(error.operation).toBe("getBorrowPageData")
  })

  it("dedupes records by stable id", () => {
    const deduped = dedupeByStableId(
      [
        { id: "row-1", label: "a" },
        { id: "row-1", label: "b" },
        { id: "row-2", label: "c" },
      ],
      "activity rows",
    )

    expect(deduped).toHaveLength(2)
    expect(deduped[0]?.label).toBe("a")
    expect(deduped[1]?.label).toBe("c")
  })
})
