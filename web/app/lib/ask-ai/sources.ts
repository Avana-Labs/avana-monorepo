const INLINE_HOSTS = new Set([
  "aave.com",
  "app.aave.com",
  "pro.aave.com",
  "governance.aave.com",
  "avana.cc",
  "www.avana.cc",
])

export function safeAskAIUrl(value: unknown, inline = false): string | undefined {
  if (typeof value !== "string") return undefined
  try {
    const url = new URL(value)
    if (url.protocol !== "https:" || url.username || url.password || url.port) return undefined
    if (inline && !INLINE_HOSTS.has(url.hostname)) return undefined
    if (/^(localhost|127\.|10\.|192\.168\.|\[)/i.test(url.hostname)) return undefined
    return url.href
  } catch {
    return undefined
  }
}

export function sanitizeAskAISources(sources: unknown[]) {
  return sources.flatMap((value) => {
    if (!value || typeof value !== "object") return []
    const row = value as Record<string, unknown>
    if (typeof row.domain !== "string" || typeof row.title !== "string") return []
    const url = safeAskAIUrl(row.url, row.kind === "aave")
    return [
      {
        domain: row.domain.slice(0, 200),
        title: row.title.slice(0, 300),
        locator: typeof row.locator === "string" ? row.locator.slice(0, 200) : "",
        ...(url ? { url } : {}),
      },
    ]
  })
}
