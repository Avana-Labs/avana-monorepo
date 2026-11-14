import { describe, expect, it } from "vitest"
import { getJwtExpirySeconds, isJwtExpired } from "@/app/lib/siwe/token-expiry"

/** Build a JWT-shaped string whose payload carries the given claims (signature is junk;
 *  these helpers never verify it). */
function fakeJwt(claims: Record<string, unknown>): string {
  const b64 = (obj: unknown) => Buffer.from(JSON.stringify(obj)).toString("base64url")
  return `${b64({ alg: "RS256", typ: "JWT" })}.${b64(claims)}.sig`
}

const NOW_MS = 1_800_000_000_000 // fixed clock (seconds = 1_800_000_000)
const NOW_S = Math.floor(NOW_MS / 1000)

describe("SIWE token expiry", () => {
  it("reads the exp claim out of a JWT payload", () => {
    expect(getJwtExpirySeconds(fakeJwt({ exp: NOW_S + 3600 }))).toBe(NOW_S + 3600)
  })

  it("returns null for missing/unparseable tokens", () => {
    expect(getJwtExpirySeconds(null)).toBeNull()
    expect(getJwtExpirySeconds("")).toBeNull()
    expect(getJwtExpirySeconds("not-a-jwt")).toBeNull()
    expect(getJwtExpirySeconds(fakeJwt({ wallet: "0xabc" }))).toBeNull() // no exp
  })

  it("treats a token still comfortably in its TTL as not expired", () => {
    expect(isJwtExpired(fakeJwt({ exp: NOW_S + 600 }), NOW_MS)).toBe(false)
  })

  it("treats an already-lapsed token as expired", () => {
    expect(isJwtExpired(fakeJwt({ exp: NOW_S - 1 }), NOW_MS)).toBe(true)
  })

  it("treats a token inside the pre-expiry skew window as expired (proactive re-sign)", () => {
    // exp is 10s in the future but within the default 30s skew → considered expired.
    expect(isJwtExpired(fakeJwt({ exp: NOW_S + 10 }), NOW_MS)).toBe(true)
  })

  it("treats a token with no readable exp as expired (can't be trusted)", () => {
    expect(isJwtExpired(null, NOW_MS)).toBe(true)
    expect(isJwtExpired(fakeJwt({ wallet: "0xabc" }), NOW_MS)).toBe(true)
  })
})
