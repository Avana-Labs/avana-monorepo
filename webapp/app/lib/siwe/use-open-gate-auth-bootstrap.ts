"use client"

import { useEffect, useState } from "react"
import { clearSiweToken, getSiweToken, setSiweToken } from "@/app/lib/siwe/auth-store"
import { isJwtExpired } from "@/app/lib/siwe/token-expiry"
import { shouldUseOpenGateSession, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"

type OpenGateTokenResponse = {
  token: string
  wallet: string
}

let openGateTokenPromise: Promise<OpenGateTokenResponse> | null = null

function readJwtIssuer(jwt: string): string | null {
  try {
    const payload = jwt.split(".")[1]
    if (!payload) return null
    const json = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/"))) as { iss?: string }
    return json.iss ?? null
  } catch {
    return null
  }
}

function isLoopbackIssuer(issuer: string | null) {
  if (!issuer) return true
  try {
    const host = new URL(issuer).hostname
    return host === "localhost" || host === "127.0.0.1" || host === "::1"
  } catch {
    return true
  }
}

function ensureOpenGateToken(): Promise<OpenGateTokenResponse> {
  if (openGateTokenPromise) return openGateTokenPromise

  openGateTokenPromise = fetch("/api/siwe/dev-token", { method: "POST" })
    .then(async (response) => {
      if (!response.ok) {
        const body = (await response.json().catch(() => null)) as { error?: string } | null
        throw new Error(body?.error ?? `dev-token ${response.status}`)
      }
      const body = (await response.json()) as { token?: string; wallet?: string }
      if (!body.token || !body.wallet) throw new Error("dev-token response missing token")
      const session = { token: body.token, wallet: body.wallet }
      setSiweToken(session.token, session.wallet)
      return session
    })
    .finally(() => {
      openGateTokenPromise = null
    })

  return openGateTokenPromise
}

/**
 * Open-gate bootstrap: ensure sessionStorage has a live Convex JWT for the
 * shared dev wallet so ConvexProviderWithAuth can authenticate wallet queries.
 * No-ops when open-gate is off or a valid non-loopback token already exists.
 */
export function useOpenGateAuthBootstrap(): { ready: boolean; error: string | null } {
  const [ready, setReady] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!shouldUseOpenGateSession()) {
      setReady(true)
      return
    }

    const existing = getSiweToken()
    if (
      existing &&
      !isJwtExpired(existing.jwt) &&
      existing.wallet === TEST_MODE_WALLET_ADDRESS.toLowerCase() &&
      !isLoopbackIssuer(readJwtIssuer(existing.jwt))
    ) {
      setReady(true)
      return
    }

    // Drop stale loopback-issuer tokens left from earlier open-gate boots.
    if (existing) clearSiweToken()

    let cancelled = false
    void ensureOpenGateToken()
      .then(() => {
        if (cancelled) return
        setError(null)
        setReady(true)
      })
      .catch((err) => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : "Failed to mint open-gate token")
        setReady(false)
      })

    return () => {
      cancelled = true
    }
  }, [])

  return { ready, error }
}
