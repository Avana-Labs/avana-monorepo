import "server-only"
import crypto from "node:crypto"
import { isIsolatedE2EStaging } from "./e2e-policy"

/**
 * RS256 JWT mint + JWK publication for the SIWE → JWT bridge, on Node crypto. The private JWK
 * comes from SIWE_JWT_PRIVATE_JWK (a throwaway key in `.env.local`; production supplies its
 * own). Convex verifies these itself by fetching `${issuer}/.well-known/jwks.json`, so this
 * module only MINTS — it never verifies its own tokens for authorization.
 */

type Jwk = JsonWebKey & { kid?: string; alg?: string; use?: string }

const CONVEX_AUDIENCE = "convex"
const SESSION_AUDIENCE = "avana-session"
const ACCESS_TTL_SECONDS = 15 * 60
const GUEST_TTL_SECONDS = 60 * 60
const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url")
}

function privateJwk(): Jwk {
  if (process.env.AVANA_E2E_STAGING === "1" && !isIsolatedE2EStaging()) {
    throw new Error("Invalid isolated E2E signing configuration")
  }
  const raw = isIsolatedE2EStaging() ? process.env.AVANA_E2E_PRIVATE_JWK : process.env.SIWE_JWT_PRIVATE_JWK
  if (!raw) throw new Error("SIWE_JWT_PRIVATE_JWK is not set (see .env.local).")
  return JSON.parse(raw) as Jwk
}

/** The public JWK (all RSA private fields stripped) for the JWKS endpoint. */
export function getPublicJwk(): Jwk {
  const { d: _d, p: _p, q: _q, dp: _dp, dq: _dq, qi: _qi, ...pub } = privateJwk()
  return { ...pub, alg: "RS256", use: "sig" }
}

/**
 * Resolve the token issuer. Convex matches `iss` against convex/auth.config.ts by EXACT string,
 * so it must be pinned via env: deriving it from the request origin makes a preview URL or
 * secondary Vercel alias mint a token that fails UNAUTHENTICATED. Request-origin fallback is
 * for local dev only; unset in a deploy is a misconfiguration and warns loudly. The trailing
 * slash is stripped so "…app/" can't mismatch a registered "…app".
 */
export function resolveIssuer(requestOrigin: string): string {
  const configured = process.env.NEXT_PUBLIC_SIWE_ISSUER?.trim()
  if (!configured && process.env.NODE_ENV === "production") {
    console.warn(
      "[siwe] NEXT_PUBLIC_SIWE_ISSUER is not set — issuer falls back to the request origin, so " +
        "wallet sign-in will fail on any non-canonical domain (preview URL, alias). Pin it to the " +
        "canonical origin and set the Convex SIWE_JWT_ISSUER env var to the SAME value.",
    )
  }
  return (configured || requestOrigin).replace(/\/+$/, "")
}

/** Mint an RS256 JWT carrying the supplied identity claims. */
function mintJwt(
  payloadClaims: Record<string, unknown>,
  issuer: string,
  { audience, ttlSeconds }: { audience: string; ttlSeconds: number },
): string {
  const jwk = privateJwk()
  const key = crypto.createPrivateKey({ key: jwk as crypto.JsonWebKeyInput["key"], format: "jwk" })
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: "RS256", typ: "JWT", kid: jwk.kid }
  const payload = {
    iss: issuer,
    aud: audience,
    iat: now,
    nbf: now,
    exp: now + ttlSeconds,
    ...payloadClaims,
  }
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`
  // RS256: RSASSA-PKCS1-v1_5 over SHA-256.
  const signature = crypto.sign("sha256", Buffer.from(signingInput), key)
  return `${signingInput}.${b64url(signature)}`
}

/**
 * Verify a wallet JWT WE minted (signature, expiry, audience, wallet scope) and return its
 * wallet. Used only to decide what to SERVER-RENDER for a visitor carrying the session cookie
 * (see app/lib/siwe/auth-store.ts); it never authorizes anything — Convex still verifies the
 * bearer token independently on every authed call. Returns null for anything not trustworthy.
 */
function verifyWalletJwt(
  token: string,
  { audience, scope }: { audience: string; scope: "wallet" | "session" },
): { wallet: string; exp: number } | null {
  const parts = token.split(".")
  if (parts.length !== 3) return null
  const [encodedHeader, encodedPayload, encodedSignature] = parts as [string, string, string]
  try {
    const header = JSON.parse(Buffer.from(encodedHeader, "base64url").toString("utf8")) as { alg?: unknown }
    if (header.alg !== "RS256") return null
    const key = crypto.createPublicKey({ key: getPublicJwk() as crypto.JsonWebKeyInput["key"], format: "jwk" })
    const valid = crypto.verify(
      "sha256",
      Buffer.from(`${encodedHeader}.${encodedPayload}`),
      key,
      Buffer.from(encodedSignature, "base64url"),
    )
    if (!valid) return null
    const payload = JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8")) as {
      aud?: unknown
      exp?: unknown
      scope?: unknown
      wallet?: unknown
    }
    const now = Math.floor(Date.now() / 1000)
    if (payload.aud !== audience || payload.scope !== scope) return null
    if (typeof payload.exp !== "number" || payload.exp <= now) return null
    if (typeof payload.wallet !== "string" || !/^0x[0-9a-f]{40}$/.test(payload.wallet)) return null
    return { wallet: payload.wallet, exp: payload.exp }
  } catch {
    return null
  }
}

/** Verify a short-lived Convex bearer token minted by this app. */
export function verifySandboxJwt(token: string): { wallet: string; exp: number } | null {
  return verifyWalletJwt(token, { audience: CONVEX_AUDIENCE, scope: "wallet" })
}

/** Verify the server-owned browser session. This token is never accepted by Convex. */
export function verifySiweSessionJwt(token: string): { wallet: string; exp: number } | null {
  return verifyWalletJwt(token, { audience: SESSION_AUDIENCE, scope: "session" })
}

/** Mint a wallet identity after SIWE verification. */
export function mintSandboxJwt(wallet: string, issuer: string): string {
  const normalized = wallet.toLowerCase()
  return mintJwt({ sub: normalized, wallet: normalized, scope: "wallet" }, issuer, {
    audience: CONVEX_AUDIENCE,
    ttlSeconds: ACCESS_TTL_SECONDS,
  })
}

/** Mint the HttpOnly browser session used to request short-lived Convex access tokens. */
export function mintSiweSessionJwt(wallet: string, issuer: string): string {
  const normalized = wallet.toLowerCase()
  return mintJwt({ sub: normalized, wallet: normalized, scope: "session" }, issuer, {
    audience: SESSION_AUDIENCE,
    ttlSeconds: SESSION_TTL_SECONDS,
  })
}

/**
 * Mint a limited Ask AI guest identity. It intentionally has no wallet claim,
 * so wallet-scoped Convex tools cannot treat it as an authenticated account.
 */
export function mintAskGuestJwt(guestId: string, issuer: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(guestId)) throw new Error("Invalid Ask AI guest id")
  return mintJwt({ sub: `ask-guest:${guestId.toLowerCase()}`, scope: "ask-ai" }, issuer, {
    audience: CONVEX_AUDIENCE,
    ttlSeconds: GUEST_TTL_SECONDS,
  })
}
