import { ZodError, type ZodType } from "zod"

export type DataSourceMode = "mock" | "live"

export type DataSourceCursor = {
  token: string
  sourceId: string
  version: string
}

export type DataSourcePageInfo = {
  nextCursor: DataSourceCursor | null
  hasMore: boolean
}

export type DataSourceWarning = {
  code: string
  message: string
  sourceId: string
}

export type DataSourceRequestContext = {
  signal?: AbortSignal
  requestId?: string
  cursor?: DataSourceCursor | null
  limit?: number
}

export type DataSourceResponse<T> = {
  data: T
  fetchedAt?: string
  pageInfo?: DataSourcePageInfo
  warnings?: DataSourceWarning[]
}

export type DataSourceAdapter = {
  id: string
  label: string
  mode: DataSourceMode
  version: string
  supportsPagination: boolean
  supportsFallback: boolean
}

type DataSourceErrorCode =
  | "aborted"
  | "auth"
  | "invalid_response"
  | "not_found"
  | "rate_limited"
  | "timeout"
  | "unavailable"
  | "unknown"
  | "unsupported"

type DataSourceErrorInit = {
  code: DataSourceErrorCode
  sourceId: string
  operation: string
  message: string
  retryable?: boolean
  statusCode?: number
  cause?: unknown
}

export class DataSourceError extends Error {
  readonly code: DataSourceErrorCode
  readonly sourceId: string
  readonly operation: string
  readonly retryable: boolean
  readonly statusCode?: number
  override readonly cause?: unknown

  constructor({ code, sourceId, operation, message, retryable = false, statusCode, cause }: DataSourceErrorInit) {
    super(message)
    this.name = "DataSourceError"
    this.code = code
    this.sourceId = sourceId
    this.operation = operation
    this.retryable = retryable
    this.statusCode = statusCode
    this.cause = cause
  }
}

export function createDataSourceAdapter({
  id,
  label,
  mode,
  version = "v1",
  supportsFallback = mode === "live",
  supportsPagination = false,
}: {
  id: string
  label: string
  mode: DataSourceMode
  version?: string
  supportsFallback?: boolean
  supportsPagination?: boolean
}): DataSourceAdapter {
  return {
    id,
    label,
    mode,
    version,
    supportsFallback,
    supportsPagination,
  }
}

function ensureRequestNotAborted(signal?: AbortSignal) {
  if (signal?.aborted) {
    throw new DataSourceError({
      code: "aborted",
      sourceId: "request",
      operation: "request",
      message: "Request aborted",
      retryable: false,
    })
  }
}

export function normalizeDataSourceError(
  error: unknown,
  adapter: DataSourceAdapter,
  operation: string,
): DataSourceError {
  if (error instanceof DataSourceError) {
    return error
  }

  if (error instanceof ZodError) {
    return new DataSourceError({
      code: "invalid_response",
      sourceId: adapter.id,
      operation,
      message: `Invalid response from ${adapter.label}`,
      retryable: false,
      cause: error,
    })
  }

  if (error instanceof DOMException && error.name === "AbortError") {
    return new DataSourceError({
      code: "aborted",
      sourceId: adapter.id,
      operation,
      message: "Request aborted",
      retryable: false,
      cause: error,
    })
  }

  if (error instanceof Error) {
    return new DataSourceError({
      code: "unknown",
      sourceId: adapter.id,
      operation,
      message: error.message,
      retryable: adapter.mode === "live",
      cause: error,
    })
  }

  return new DataSourceError({
    code: "unknown",
    sourceId: adapter.id,
    operation,
    message: `Unknown source failure in ${adapter.label}`,
    retryable: adapter.mode === "live",
    cause: error,
  })
}

function shouldFallbackFromError(error: DataSourceError) {
  return (
    error.code === "unsupported" ||
    error.code === "unavailable" ||
    error.code === "timeout" ||
    error.code === "rate_limited"
  )
}

function parseSourcePayload<T>(payload: DataSourceResponse<unknown>, schema?: ZodType<T>) {
  if (!schema) {
    return payload.data as T
  }
  return schema.parse(payload.data)
}

export async function executeSourceLoad<TSource extends { adapter: DataSourceAdapter }, TData>({
  primary,
  fallback,
  operation,
  context,
  schema,
  load,
}: {
  primary: TSource
  fallback?: TSource
  operation: string
  context?: DataSourceRequestContext
  schema?: ZodType<TData>
  load: (source: TSource, context: DataSourceRequestContext) => Promise<DataSourceResponse<TData>>
}): Promise<DataSourceResponse<TData>> {
  const requestContext = context ?? {}

  async function run(source: TSource) {
    const payload = await load(source, requestContext)
    ensureRequestNotAborted(requestContext.signal)

    if (!payload || typeof payload !== "object" || !("data" in payload)) {
      throw new Error("Source response must include a data field")
    }

    return {
      ...payload,
      data: parseSourcePayload(payload as DataSourceResponse<unknown>, schema),
    }
  }

  try {
    ensureRequestNotAborted(requestContext.signal)
    return await run(primary)
  } catch (error) {
    const primaryAdapter = primary.adapter
    const normalizedPrimaryError = normalizeDataSourceError(error, primaryAdapter, operation)

    if (
      !fallback ||
      fallback === primary ||
      !primaryAdapter.supportsFallback ||
      !shouldFallbackFromError(normalizedPrimaryError)
    ) {
      throw normalizedPrimaryError
    }

    try {
      return await run(fallback)
    } catch (fallbackError) {
      const fallbackAdapter = fallback.adapter
      throw normalizeDataSourceError(fallbackError, fallbackAdapter, operation)
    }
  }
}

export function dedupeByStableId<T extends { id: string }>(records: T[], label: string) {
  const deduped = new Map<string, T>()

  for (const record of records) {
    if (!record.id) {
      throw new DataSourceError({
        code: "invalid_response",
        sourceId: label,
        operation: "dedupeByStableId",
        message: `${label} record is missing a stable id`,
        retryable: false,
      })
    }

    if (!deduped.has(record.id)) {
      deduped.set(record.id, record)
    }
  }

  return [...deduped.values()]
}

export function assertStableRecordIds<T extends { id: string }>(records: T[], label: string) {
  const seen = new Set<string>()

  for (const record of records) {
    if (!record.id) {
      throw new DataSourceError({
        code: "invalid_response",
        sourceId: label,
        operation: "assertStableRecordIds",
        message: `${label} record is missing a stable id`,
        retryable: false,
      })
    }

    if (seen.has(record.id)) {
      throw new DataSourceError({
        code: "invalid_response",
        sourceId: label,
        operation: "assertStableRecordIds",
        message: `${label} contains duplicate id ${record.id}`,
        retryable: false,
      })
    }

    seen.add(record.id)
  }

  return records
}
