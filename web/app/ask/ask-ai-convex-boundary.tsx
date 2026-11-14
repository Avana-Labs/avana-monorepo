"use client"

import { useCallback, useEffect, useState, type ReactNode } from "react"
import { ConvexProviderWithAuth, ConvexReactClient } from "convex/react"
import { fetchSiweAccessToken, getSiweSession } from "@/app/lib/siwe/auth-store"
import { useLiveSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import {
  getAskAIGuestToken,
  refreshAskAIGuestToken,
  setAskAIGuestToken,
  useAskAIGuestToken,
  type AskAIGuestToken,
} from "@/app/lib/ask-ai/guest-auth-store"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { AskAILoadingBody } from "./components/ask-ai-skeleton"

// Guest-session failures in plain words; the route's 429 is a real per-network budget, 503 means
// the shared limiter is unavailable. Never surface the raw status code.
const GUEST_SESSION_ERRORS = {
  limited: "Too many new Ask AI sessions from this network. Try again later.",
  unavailable: "Ask AI is temporarily unavailable. Try again in a moment.",
} as const
type GuestSessionError = keyof typeof GUEST_SESSION_ERRORS

const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL
const askAIConvexClient = convexUrl && /^https?:\/\//.test(convexUrl) ? new ConvexReactClient(convexUrl) : null

function useAskAIAuth() {
  const guest = useAskAIGuestToken()
  const siwe = useLiveSiweToken()
  // Convex calls this before the token expires (forceRefreshToken) and after any auth-expired
  // error. Reading the stores here (rather than closing over a snapshot) keeps it current, and
  // re-minting on refresh is what stops a guest session from silently dropping at the 1h TTL.
  const fetchAccessToken = useCallback(async ({ forceRefreshToken }: { forceRefreshToken: boolean }) => {
    if (getSiweSession()) return fetchSiweAccessToken(forceRefreshToken)
    const current = getAskAIGuestToken()
    if (current && !forceRefreshToken) return current.jwt
    return (await refreshAskAIGuestToken()) ?? current?.jwt ?? null
  }, [])
  const isAuthenticated = siwe != null || guest != null
  return { isLoading: false, isAuthenticated, fetchAccessToken }
}

export function AskAIConvexBoundary({ children }: { children: ReactNode }) {
  const guest = useAskAIGuestToken()
  const siwe = useLiveSiweToken()
  const hasValidSiwe = Boolean(siwe)
  const [loading, setLoading] = useState(() => Boolean(askAIConvexClient && !getSiweSession() && !guest))
  const { t } = useTranslation()
  const [error, setError] = useState<GuestSessionError | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!askAIConvexClient || getSiweSession() || getAskAIGuestToken()) {
      setLoading(false)
      return
    }
    const controller = new AbortController()
    void fetch("/api/ask-ai/session", { method: "POST", signal: controller.signal })
      .then(async (response) => {
        if (response.status === 429) {
          setError("limited")
          return
        }
        if (!response.ok) throw new Error(`Guest session failed (${response.status})`)
        const token = (await response.json()) as AskAIGuestToken
        setAskAIGuestToken(token)
      })
      .catch(() => {
        if (controller.signal.aborted) return
        setError("unavailable")
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [attempt])

  // Signed-in Ask keeps AvanaSessionProviders (and its Convex client) mounted above
  // this boundary. Nesting another ConvexProviderWithAuth would remount queries and
  // fight the parent auth — just use the existing tree.
  if (hasValidSiwe) return <>{children}</>
  if (!askAIConvexClient) return <>{children}</>
  if (loading) return <AskAILoadingBody />
  if (error) {
    return (
      <main className="flex min-h-[50vh] flex-col items-center justify-center gap-4 px-6 text-sm text-muted-foreground">
        <p role="alert">{t(GUEST_SESSION_ERRORS[error])}</p>
        <button
          type="button"
          onClick={() => {
            setError(null)
            setLoading(true)
            setAttempt((current) => current + 1)
          }}
          className="inline-flex h-10 items-center justify-center rounded-full bg-brand px-5 text-[14px] text-white hover:bg-brand/90"
        >
          {t("Retry")}
        </button>
      </main>
    )
  }
  return (
    <ConvexProviderWithAuth client={askAIConvexClient} useAuth={useAskAIAuth}>
      {children}
    </ConvexProviderWithAuth>
  )
}
