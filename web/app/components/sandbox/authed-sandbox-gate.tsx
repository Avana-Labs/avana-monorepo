"use client"

import { useEffect, useState, type ReactNode } from "react"
import { usePathname, useRouter } from "next/navigation"
import { useConvexAuth, useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { SiweConvexProvider } from "@/app/lib/convex/siwe-convex-provider"
import { requiresOnboarding } from "@/app/lib/route-access"
import { clearGetStartedIntent, hasGetStartedIntent } from "@/app/lib/web3/get-started-intent"
import { trackEvent } from "@/app/lib/analytics/track-event"
import { ONBOARDED_COOKIE } from "./onboarded-cookie"
import { OnboardingFlow, OnboardingUnavailable, type OnboardingGateState } from "./onboarding-flow"

type WalletOnlyState = Omit<OnboardingGateState, "economy">

export type GateVerdict = "unknown" | "done" | "blocked"

/**
 * Per-wallet "onboarding is done" memo, as a cookie so the SERVER can read it too. Convex
 * remains the authority — the cookie only lets a returning wallet get the product
 * server-rendered (and painted immediately) instead of staring at a skeleton for the
 * WebSocket → auth → query round trip. If Convex later disagrees the host swaps to the
 * onboarding flow and the cookie is cleared.
 */
function writeOnboardedCookie(wallet: string, done: boolean) {
  try {
    const secure = location.protocol === "https:" ? "; secure" : ""
    const maxAge = done ? 60 * 60 * 24 * 30 : 0
    document.cookie = `${ONBOARDED_COOKIE}=${done ? wallet.toLowerCase() : ""}; max-age=${maxAge}; path=/; samesite=lax${secure}`
  } catch {
    // Cookies unavailable — purely an optimisation, ignore.
  }
}

// Content-only shell: the persistent site header is rendered above the gate in the
// root layout, so rendering another <Header /> here doubled it for every gate state.
function LockedShell({ children }: { children: ReactNode }) {
  return <main className="flex flex-1 px-5 py-6 sm:px-8">{children}</main>
}

function OfflineGate() {
  return (
    <LockedShell>
      <OnboardingUnavailable
        onRetry={() => window.location.reload()}
        headlineMuted="We can't reach the sandbox right now."
        headlineActive="Please try again in a moment."
        note="Your session is safe. This is a temporary connection issue, not your wallet."
      />
    </LockedShell>
  )
}

function CheckerBody({
  wallet,
  optimistic,
  onVerdict,
}: {
  wallet: string
  optimistic: boolean
  onVerdict: (verdict: GateVerdict) => void
}) {
  const pathname = usePathname()
  const router = useRouter()
  const isOpenRoute = !requiresOnboarding(pathname)
  // Wallet queries throw UNAUTHENTICATED until Convex has verified the SIWE JWT, so hold the
  // subscription (`"skip"`) instead of tripping the gate's error boundary on first render.
  const { isAuthenticated } = useConvexAuth()
  const gate = useQuery(api.sandbox.onboarding.getOnboardingGateState, isAuthenticated ? { wallet } : "skip") as
    (OnboardingGateState & { economy: OnboardingGateState["economy"] | null }) | undefined
  const walletState = gate as WalletOnlyState | undefined
  const isDone = gate?.onboardingStep === "done"
  const economy = gate?.economy ?? undefined
  const [timedOut, setTimedOut] = useState(false)

  useEffect(() => {
    if (walletState !== undefined) {
      setTimedOut(false)
      return
    }
    const timer = setTimeout(() => setTimedOut(true), 12000)
    return () => clearTimeout(timer)
  }, [walletState])

  // Report to the host (which owns the page's mount) only once the verdict is renderable:
  // "blocked" implies the onboarding UI below has everything it needs to paint.
  const blockedReady = walletState !== undefined && !isDone && economy !== undefined
  const offline = walletState === undefined && timedOut && !optimistic && !isOpenRoute
  useEffect(() => {
    if (walletState === undefined) return
    writeOnboardedCookie(wallet, walletState.onboardingStep === "done")
  }, [wallet, walletState])
  useEffect(() => {
    if (isDone) onVerdict("done")
    else if (blockedReady || offline) onVerdict("blocked")
  }, [isDone, blockedReady, offline, onVerdict])

  // Signed in from a Get Started click: a wallet that still has to onboard goes to the dashboard
  // (where the flow starts); an onboarded wallet stays on its page. A session restored on reload
  // carries no intent and is never moved.
  useEffect(() => {
    if (walletState === undefined || !hasGetStartedIntent()) return
    clearGetStartedIntent()
    trackEvent("get_started_signed_in", { onboarded: isDone })
    if (!isDone && isOpenRoute) router.push("/dashboard")
  }, [walletState, isDone, isOpenRoute, router])

  if (isDone || walletState === undefined) return offline ? <OfflineGate /> : null
  // Open routes keep the page; the onboarding flow lives on the dashboard and umbrella.
  if (economy === undefined || isOpenRoute) return null
  return (
    <LockedShell>
      <OnboardingFlow wallet={wallet} state={{ ...walletState, economy }} />
    </LockedShell>
  )
}

/**
 * Signed-in gate CHECKER: confirms with Convex that the wallet finished onboarding and tells
 * the host (`SandboxGate`) whether the product may stay mounted. It renders as a SIBLING of
 * the page, never as its parent, so the server-rendered product survives this chunk loading
 * and the verdict arriving without a remount. Renders the onboarding flow itself when the
 * wallet is not done. Uses the Convex provider mounted by the host (falls back to its own).
 */
export function AuthedGateChecker(props: {
  wallet: string
  optimistic: boolean
  onVerdict: (verdict: GateVerdict) => void
}) {
  return (
    <SiweConvexProvider>
      <CheckerBody {...props} />
    </SiweConvexProvider>
  )
}
