import crypto from "node:crypto"
import { ConvexHttpClient } from "convex/browser"
import { api } from "@/convex/_generated/api"

export const ASK_AI_GUEST_COOKIE = "avana_ask_guest"
const GUEST_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
export const MINT_THROTTLE_MAX = 30
const MINT_THROTTLE_WINDOW_MS = 60 * 60 * 1_000
const mintHits = new Map<string, number[]>()

function guestCookieSecret(): string | null {
  return process.env.ASK_AI_GUEST_SECRET || process.env.CONVEX_RATE_LIMIT_SECRET || null
}

function hmac(id: string, secret: string): string {
  return crypto.createHmac("sha256", secret).update(id).digest("base64url")
}

/** Server-issued guest cookie value: `<uuid>.<hmac>` (bare `<uuid>` only when no secret is set). */
export function signGuestId(id: string, secret = guestCookieSecret()): string {
  return secret ? `${id}.${hmac(id, secret)}` : id
}

function verifySignedGuestId(value: string, secret: string): string | null {
  const dot = value.lastIndexOf(".")
  if (dot <= 0) return null
  const id = value.slice(0, dot)
  const sig = value.slice(dot + 1)
  if (!GUEST_ID_PATTERN.test(id)) return null
  const expected = Buffer.from(hmac(id, secret))
  const actual = Buffer.from(sig)
  if (actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) return null
  return id
}

export function readAskGuestId(cookieHeader: string | null, secret = guestCookieSecret()): string | null {
  const value = cookieHeader
    ?.split(";")
    .map((part) => part.trim().split("="))
    .find(([name]) => name === ASK_AI_GUEST_COOKIE)?.[1]
  if (!value) return null
  // Only a server-signed cookie counts as an existing guest, so a forged valid-format UUID cannot
  // skip the per-IP mint throttle (the budget-drain bypass). With no secret configured, accept a
  // well-formed id only outside production so local dev keeps working.
  if (secret) return verifySignedGuestId(value, secret)
  if (process.env.NODE_ENV === "production") return null
  return GUEST_ID_PATTERN.test(value) ? value : null
}

export function readClientIp(request: Request) {
  // Prefer the platform-set, unforgeable client IP. A raw leftmost X-Forwarded-For is
  // client-controllable, so it is only the last-resort fallback (local dev / non-Vercel).
  const trusted = request.headers.get("x-vercel-forwarded-for")?.split(",")[0]?.trim()
  if (trusted) return trusted
  const realIp = request.headers.get("x-real-ip")?.trim()
  if (realIp) return realIp
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
  return forwarded || "unknown"
}

export function allowGuestMint(ip: string, now = Date.now()) {
  const windowStart = now - MINT_THROTTLE_WINDOW_MS
  const recent = (mintHits.get(ip) ?? []).filter((ts) => ts > windowStart)
  if (recent.length >= MINT_THROTTLE_MAX) {
    mintHits.set(ip, recent)
    return false
  }
  recent.push(now)
  mintHits.set(ip, recent)
  return true
}

export function resetGuestMintThrottle() {
  mintHits.clear()
}

export type GuestMintDecision = "allowed" | "limited" | "unavailable"

/**
 * Whether a new guest session may be minted for this IP. The Vercel deployment shares one budget
 * through Convex and fails closed when that limiter can't be reached (missing/mismatched secret,
 * Convex down), reported as "unavailable" so guests aren't told they were rate limited. Anywhere
 * else (local dev, a local `next start`) falls back to the per-instance limiter.
 */
export async function guestMintDecision(ip: string): Promise<GuestMintDecision> {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  const secret = process.env.CONVEX_RATE_LIMIT_SECRET
  if (url && secret) {
    try {
      const client = new ConvexHttpClient(url)
      const { ok } = await client.mutation(api.askAI.recordGuestMint, { ip, secret })
      return ok ? "allowed" : "limited"
    } catch (error) {
      console.error("[ask-ai] guest mint limiter unreachable", error)
    }
  }
  if (process.env.NODE_ENV === "production" && process.env.VERCEL && url) return "unavailable"
  return allowGuestMint(ip) ? "allowed" : "limited"
}
