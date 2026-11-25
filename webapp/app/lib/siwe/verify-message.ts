import type { Address } from "viem"
import { createSiweMessage, parseSiweMessage, validateSiweMessage } from "viem/siwe"

/** How long after `Issued At` a message is accepted: the nonce cookie's lifetime. */
export const SIWE_MAX_AGE_MS = 10 * 60 * 1000
/** Clock skew tolerated between the wallet's `Issued At` and the server clock. */
export const SIWE_CLOCK_SKEW_MS = 60 * 1000

export type SiweCheck = {
  /** This origin's host (`Host` header); the message's domain and URI host must equal it. */
  host: string
  /** The nonce issued to this browser. */
  nonce: string
  /** The app's chain, or its chains (Ethereum and Base of this network). */
  chainId: number | readonly number[]
  now?: Date
}

export type SiweCheckResult = { ok: true; address: Address } | { ok: false; status: 400 | 401; error: string }

const fail = (status: 400 | 401, error: string): SiweCheckResult => ({ ok: false, status, error })

/**
 * Strict EIP-4361 check of a message before its signature is verified. The message is parsed
 * with viem, must rebuild byte for byte from its parsed fields (no extra, repeated or reordered
 * lines), and must carry every field this app signs. It is then bound to this origin, nonce and
 * chain, and to its time window: `Issued At` no later than now plus the skew and no older than
 * the nonce lifetime; `Expiration Time`, when present, after `Issued At` and still in the future;
 * `Not Before`, when present, already reached.
 */
export function checkSiweMessage(message: string, check: SiweCheck): SiweCheckResult {
  const now = check.now ?? new Date()
  const parsed = parseSiweMessage(message)
  const { address, domain, uri, version, chainId, nonce, issuedAt, expirationTime } = parsed
  if (!address || !domain || !uri || version !== "1" || !chainId || !nonce || !issuedAt) {
    return fail(400, "malformed SIWE message")
  }

  let canonical: string
  try {
    canonical = createSiweMessage({ ...parsed, address, domain, uri, version, chainId, nonce, issuedAt })
  } catch {
    return fail(400, "malformed SIWE message")
  }
  if (canonical !== message) return fail(400, "malformed SIWE message")

  let uriHost: string
  try {
    uriHost = new URL(uri).host
  } catch {
    return fail(400, "malformed SIWE URI")
  }
  if (domain !== check.host) return fail(401, "SIWE domain does not match this origin")
  if (uriHost !== check.host) return fail(401, "SIWE URI does not match this origin")
  const allowed = typeof check.chainId === "number" ? [check.chainId] : check.chainId
  if (!allowed.includes(chainId)) return fail(401, "SIWE chain does not match this app")
  if (nonce !== check.nonce) return fail(401, "invalid or expired nonce")

  const issued = issuedAt.getTime()
  if (Number.isNaN(issued)) return fail(400, "malformed SIWE Issued At")
  if (issued > now.getTime() + SIWE_CLOCK_SKEW_MS) return fail(401, "SIWE message is issued in the future")
  if (now.getTime() - issued > SIWE_MAX_AGE_MS) return fail(401, "SIWE message has expired")
  if (expirationTime && !(expirationTime.getTime() > issued)) {
    return fail(400, "SIWE Expiration Time is not after Issued At")
  }

  if (!validateSiweMessage({ message: parsed, domain: check.host, nonce: check.nonce, time: now })) {
    return fail(401, "SIWE message is not valid now")
  }
  return { ok: true, address }
}
