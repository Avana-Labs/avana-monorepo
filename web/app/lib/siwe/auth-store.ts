"use client"

import { shouldUseOpenGateSession } from "@/app/lib/test-mode"
import { isJwtExpired } from "./token-expiry"

/** Public client state. The bearer credential is deliberately not part of it. */
export type SiweSession = { wallet: string }
type SiweToken = { jwt: string; wallet: string }

const AUTH_EVENT_KEY = "avana.siwe.event.v2"
const LEGACY_STORAGE_KEY = "avana.siwe.token.v1"
const CHANNEL_NAME = "avana-auth"

let current: SiweSession | null = null
let accessToken: SiweToken | null = null
let refreshPromise: Promise<string | null> | null = null
let channel: BroadcastChannel | null = null
const listeners = new Set<() => void>()

function emit() {
  for (const listener of listeners) listener()
}

function applySession(session: SiweSession | null) {
  const normalized = session ? { wallet: session.wallet.toLowerCase() } : null
  if (current?.wallet === normalized?.wallet) return
  current = normalized
  if (!normalized || accessToken?.wallet !== normalized.wallet) accessToken = null
  emit()
}

function authChannel() {
  // Vitest files execute concurrently in one process; a real BroadcastChannel
  // would make isolated test stores behave like tabs and clear each other.
  if (process.env.NODE_ENV === "test" || channel || typeof BroadcastChannel === "undefined") return channel
  channel = new BroadcastChannel(CHANNEL_NAME)
  channel.addEventListener("message", (event: MessageEvent<SiweSession | null>) => applySession(event.data))
  return channel
}

function broadcastSession(session: SiweSession | null) {
  authChannel()?.postMessage(session)
  try {
    window.localStorage.setItem(AUTH_EVENT_KEY, JSON.stringify({ session, at: Date.now() }))
  } catch {
    // Storage may be unavailable. BroadcastChannel remains the primary path.
  }
}

function handleStorage(event: StorageEvent) {
  if (event.key === LEGACY_STORAGE_KEY) {
    try {
      window.localStorage.removeItem(LEGACY_STORAGE_KEY)
      window.sessionStorage.removeItem(LEGACY_STORAGE_KEY)
    } catch {
      // Best-effort removal of the deprecated bearer persistence.
    }
    return
  }
  if (event.key !== AUTH_EVENT_KEY || !event.newValue) return
  try {
    const parsed = JSON.parse(event.newValue) as { session?: SiweSession | null }
    applySession(parsed.session ?? null)
  } catch {
    // Ignore malformed events from unrelated/old application code.
  }
}

if (typeof window !== "undefined") {
  try {
    window.localStorage.removeItem(LEGACY_STORAGE_KEY)
    window.sessionStorage.removeItem(LEGACY_STORAGE_KEY)
  } catch {
    // Storage may be unavailable.
  }
  window.addEventListener("storage", handleStorage)
  authChannel()
}

export function hydrateSiweSession(session: SiweSession | null) {
  if (session) applySession(session)
}

export function getSiweSession(): SiweSession | null {
  return current
}

/** Memory-only access-token snapshot for non-reactive adapters. */
export function getSiweToken(): SiweToken | null {
  if (accessToken && isJwtExpired(accessToken.jwt)) accessToken = null
  return accessToken
}

/** Accept an already-minted access token in dev/open-gate mode only. */
export function setSiweToken(jwt: string, wallet: string) {
  const session = { wallet: wallet.toLowerCase() }
  accessToken = { jwt, wallet: session.wallet }
  applySession(session)
  broadcastSession(session)
}

export function setSiweSession(wallet: string) {
  const session = { wallet: wallet.toLowerCase() }
  applySession(session)
  broadcastSession(session)
}

export function clearSiweToken() {
  accessToken = null
  refreshPromise = null
  applySession(null)
  broadcastSession(null)
}

export function subscribeSiwe(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** Mint one access token for all simultaneous Convex consumers. No polling. */
export async function fetchSiweAccessToken(forceRefresh = false): Promise<string | null> {
  const cached = getSiweToken()
  if (!forceRefresh && cached) return cached.jwt
  if (!current) return null
  if (refreshPromise) return refreshPromise

  // Open-gate has a memory JWT from `/api/siwe/dev-token`, not an `avana_siwe` cookie.
  // Convex often force-refreshes via this helper; hitting `/api/siwe/token` returns 401 and
  // used to clear the open-gate session — then wallet mutations fail as UNAUTHENTICATED
  // while the UI still looks signed in via the TEST_MODE_WALLET fallback.
  const openGate = shouldUseOpenGateSession()
  const refreshUrl = openGate ? "/api/siwe/dev-token" : "/api/siwe/token"

  refreshPromise = fetch(refreshUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    cache: "no-store",
  })
    .then(async (response) => {
      if (response.status === 401) {
        if (!openGate) {
          applySession(null)
          broadcastSession(null)
        }
        return null
      }
      if (!response.ok) throw new Error(`Could not refresh wallet session (${response.status}).`)
      const next = (await response.json()) as { token: string; wallet: string }
      if (!current) return null
      if (next.wallet.toLowerCase() !== current.wallet) {
        applySession(null)
        broadcastSession(null)
        return null
      }
      accessToken = { jwt: next.token, wallet: current.wallet }
      return next.token
    })
    // Never reject: Convex pauses its socket while it awaits this token and only resumes it on
    // success (authentication_manager.setConfig has no catch), so a network blip or a 5xx here
    // left every signed-in query hanging until a reload. Keep a still-valid token; else none.
    .catch(() => getSiweToken()?.jwt ?? null)
    .finally(() => {
      refreshPromise = null
    })

  return refreshPromise
}
