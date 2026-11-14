import { DataSourceError } from "@/app/lib/data/core/source-runtime"

export function resolveDefaultWithAuthFallback<T>(options: {
  loadPrimary: () => T
  loadFallback: () => T
  allowFallback: boolean
}) {
  const { loadPrimary, loadFallback, allowFallback } = options
  try {
    return loadPrimary()
  } catch (error) {
    if (allowFallback && error instanceof DataSourceError && error.code === "auth") {
      return loadFallback()
    }
    throw error
  }
}
