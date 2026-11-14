export function askAIHref(returnHref: string) {
  return `/ask?return=${encodeURIComponent(returnHref)}`
}

// Throwaway origin: the return value is resolved against it and kept only if it stays on it.
const RETURN_ORIGIN = "https://return.invalid"

/**
 * Where closing Ask AI goes: the launch route, or home for anything unsafe. The value is resolved
 * like a browser would, not prefix-checked: "/\evil.example" and "/\t/evil.example" (a decoded
 * %09) passed the old string checks, and browsers normalise both to the off-site "//evil.example".
 */
export function resolveAskAICloseHref(returnHref: string | null | undefined) {
  if (!returnHref?.startsWith("/")) return "/"
  let url: URL
  try {
    url = new URL(returnHref, RETURN_ORIGIN)
  } catch {
    return "/"
  }
  if (url.origin !== RETURN_ORIGIN || url.pathname.startsWith("/ask")) return "/"
  return `${url.pathname}${url.search}${url.hash}`
}
