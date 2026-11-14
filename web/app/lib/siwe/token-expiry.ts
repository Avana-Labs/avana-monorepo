/**
 * Read the `exp` claim out of a SIWE JWT so the client can tell when its session has
 * lapsed. The token is minted server-side (see jwt.ts) with a short TTL; without this
 * the client can't distinguish "signed in" from "holding an expired token", and an
 * expired token silently fails every Convex query.
 *
 * Pure + dependency-free: only base64url-decodes the payload segment, never verifies
 * the signature (Convex does that). Returns null for anything unparseable.
 */

/** Expiry (epoch seconds) from a JWT's `exp` claim, or null if absent/unparseable. */
export function getJwtExpirySeconds(jwt: string | null | undefined): number | null {
  if (!jwt) return null
  const payload = jwt.split(".")[1]
  if (!payload) return null
  try {
    const json = base64UrlDecode(payload)
    const claims = JSON.parse(json) as { exp?: unknown }
    return typeof claims.exp === "number" && Number.isFinite(claims.exp) ? claims.exp : null
  } catch {
    return null
  }
}

/**
 * Whether the token is expired (or within `skewSeconds` of expiry). A small skew lets
 * callers treat a nearly-expired token as already gone, so re-auth happens before a
 * Convex call fails rather than after. A token with no readable `exp` is treated as
 * expired — we can't trust it.
 */
export function isJwtExpired(jwt: string | null | undefined, nowMs = Date.now(), skewSeconds = 30): boolean {
  const exp = getJwtExpirySeconds(jwt)
  if (exp == null) return true
  return exp - skewSeconds <= Math.floor(nowMs / 1000)
}

function base64UrlDecode(input: string): string {
  const base64 = input.replace(/-/g, "+").replace(/_/g, "/")
  if (typeof atob === "function") return atob(base64)
  // Node fallback (SSR / non-DOM runtimes).
  return Buffer.from(base64, "base64").toString("binary")
}
