import type { DataSourceMode } from "@/app/lib/data/core/source-runtime"
import { shouldUseMockDataSource } from "@/app/lib/test-mode"

export function resolveDataSourceMode(): DataSourceMode {
  return shouldUseMockDataSource() ? "mock" : "live"
}
