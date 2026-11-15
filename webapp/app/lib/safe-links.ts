/**
 * Link guards shared by every page: same-origin return paths and external https links.
 */

const INTERNAL_BASE = "https://avana.invalid"
// Browsers read "\" as "/" and strip tab, CR and LF from URLs, so "/\evil.example" and
// "/\t/evil.example" both resolve to another origin. Any control character or backslash fails.
function hasUnsafePathChar(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    if (code < 0x20 || code === 0x7f || code === 0x5c) return true
  }
  return false
}

function isRootRelative(value: string): boolean {
  return value.startsWith("/") && !value.startsWith("//") && !hasUnsafePathChar(value)
}

/**
 * A same-origin path from an untrusted query value, or null. The value must be root-relative
 * before and after one round of percent-decoding, and must resolve to this origin.
 */
export function safeInternalHref(value: string | null | undefined): string | null {
  if (!value || !isRootRelative(value)) return null
  let decoded: string
  try {
    decoded = decodeURIComponent(value)
  } catch {
    return null
  }
  if (!isRootRelative(decoded)) return null
  let url: URL
  try {
    url = new URL(value, INTERNAL_BASE)
  } catch {
    return null
  }
  if (url.origin !== INTERNAL_BASE) return null
  return `${url.pathname}${url.search}${url.hash}`
}

/** True only for an absolute `https:` URL with a host and no embedded credentials. */
export function isSafeExternalUrl(value: string | null | undefined): value is string {
  if (!value) return false
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return false
  }
  return url.protocol === "https:" && url.hostname.length > 0 && !url.username && !url.password
}

/** Opens a safe external URL in a new tab with no opener and no referrer; ignores anything else. */
export function openExternal(value: string | null | undefined): void {
  if (!isSafeExternalUrl(value)) return
  window.open(value, "_blank", "noopener,noreferrer")
}
