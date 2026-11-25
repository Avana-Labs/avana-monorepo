import { ConvexHttpClient } from "convex/browser"
import { api } from "@/convex/_generated/api"

type Bucket = { count: number; resetAt: number }

const buckets = new Map<string, Bucket>()

export function clientKey(request: Request) {
  const forwardedFor = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
  const realIp = request.headers.get("x-real-ip")?.trim()
  return forwardedFor || realIp || "unknown"
}

export function assertSameOrigin(request: Request) {
  const origin = request.headers.get("origin")
  const host = request.headers.get("host")
  // Fail CLOSED: these guards protect state-changing POST endpoints (SIWE
  // nonce/verify/dev-token), and browsers always attach an Origin to such
  // cross-origin-capable requests. A missing Origin or Host is treated as a
  // mismatch rather than waved through, so a forged request stripped of its
  // Origin can't bypass the check.
  if (!origin || !host) return false
  try {
    return new URL(origin).host === host
  } catch {
    return false
  }
}

/**
 * Same-origin guard tuned for read-only GET endpoints (e.g. /api/fx-rates).
 *
 * A browser does NOT attach an `Origin` header to a plain same-origin GET, so
 * `assertSameOrigin` (which fails closed on a missing Origin) rejects the app's
 * own legitimate fetch. That's correct for a state-changing POST but wrong for a
 * cheap cached read the app fetches from its own pages.
 *
 * Instead we trust the browser-set `Sec-Fetch-Site` metadata header, which the
 * page CANNOT forge cross-origin: `same-origin` / `same-site` / `none` (a
 * top-level navigation / direct hit) are allowed, `cross-site` is blocked. When
 * the header is absent (older clients, server-to-server), fall back to comparing
 * the `Origin` (if the client sent one) against the host, and otherwise allow —
 * the endpoint is read-only and returns public FX data, so the goal is only to
 * deny another site scripting our egress, not to gate reads behind a header no
 * same-origin GET carries.
 */
export function assertSameOriginRead(request: Request) {
  const secFetchSite = request.headers.get("sec-fetch-site")
  if (secFetchSite) {
    return secFetchSite === "same-origin" || secFetchSite === "same-site" || secFetchSite === "none"
  }
  const origin = request.headers.get("origin")
  const host = request.headers.get("host")
  if (origin && host) {
    try {
      return new URL(origin).host === host
    } catch {
      return false
    }
  }
  // No cross-origin signal at all → a same-origin GET or a server-side fetch.
  return true
}

/**
 * Per-instance in-memory rate limit. On horizontally-scaled deploys each instance keeps
 * its own bucket, so a burst can multiply by the replica count. Only a synchronous
 * fallback for tests and single-process dev; `rateLimitShared` guards real boundaries.
 */
function rateLimit(key: string, limit: number, windowMs: number) {
  const now = Date.now()
  const bucket = buckets.get(key)
  if (!bucket || bucket.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs })
    return true
  }
  if (bucket.count >= limit) return false
  bucket.count += 1
  return true
}

let cachedClient: ConvexHttpClient | null = null
function sharedStoreClient(): ConvexHttpClient | null {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL || process.env.CONVEX_URL
  if (!url) return null
  if (cachedClient) return cachedClient
  cachedClient = new ConvexHttpClient(url)
  return cachedClient
}

/**
 * Shared-store rate limit backed by Convex `rateLimitBuckets`. Convex mutations are
 * serializable, so one counter spans every Next instance. Falls back to the in-memory
 * bucket when no Convex URL is configured, so a limiter never hard-depends on Convex.
 */
export async function rateLimitShared(key: string, limit: number, windowMs: number): Promise<boolean> {
  const client = sharedStoreClient()
  if (!client) return rateLimit(key, limit, windowMs)
  const secret = process.env.CONVEX_RATE_LIMIT_SECRET
  if (!secret) return process.env.NODE_ENV === "production" ? false : rateLimit(key, limit, windowMs)
  try {
    const result = await client.mutation(api.rateLimits.consume, { key, limit, windowMs, secret })
    return result.allowed
  } catch {
    // Security boundary in production: a distributed deployment cannot safely
    // replace the shared counter with independent per-instance buckets.
    return process.env.NODE_ENV === "production" ? false : rateLimit(key, limit, windowMs)
  }
}
