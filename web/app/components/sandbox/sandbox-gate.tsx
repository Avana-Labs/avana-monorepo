"use client"

import dynamic from "next/dynamic"
import type { ReactNode } from "react"
import { usePathname } from "next/navigation"
import { hasConvexClient } from "@/app/lib/convex/market-liquidity-provider"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { IS_DEV_SHORTCUT_MODE } from "@/app/lib/test-mode"
import { requiresOnboarding } from "@/app/lib/route-access"
import { TransactAccessContext } from "@/app/lib/transact-access"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { GuestOnboardingFlow } from "./guest-onboarding-flow"
import styles from "./onboarding-flow.module.css"

// Signed-in-only module: Convex provider + onboarding checker. SSR-enabled dynamic
// import keeps the Convex client runtime out of the guest layout entry while still
// shipping product HTML for returning wallets. Rendering this only when signed in
// matters — a dynamic import that always mounts still lands in the initial graph.
const SignedInSandboxGate = dynamic(() => import("./signed-in-sandbox-gate").then((mod) => mod.SignedInSandboxGate))

// Content-only shell for the gate's focused states (onboarding / error). The
// persistent site header + frame are rendered above the gate now, so this only
// owns the inner content padding.
function LockedShell({ children }: { children: ReactNode }) {
  return <main className="flex flex-1 px-5 py-6 sm:px-8">{children}</main>
}

function GateUnavailable({ variant = "error" }: { variant?: "error" | "offline" }) {
  const { t } = useTranslation()
  // A crash inside the gated app is OUR bug, not an auth problem — don't tell the
  // user to "reconnect their wallet" for a render error. Only the genuine
  // Convex-unreachable case talks about connectivity.
  const copy =
    variant === "offline"
      ? {
          headlineMuted: "We can't reach the sandbox right now.",
          headlineActive: "Please try again in a moment.",
          note: "Your session is safe. This is a temporary connection issue, not your wallet.",
        }
      : {
          headlineMuted: "Something went wrong.",
          headlineActive: "We couldn't load this page.",
          note: "This is on our side, not your wallet. Try again, and let us know if it keeps happening.",
        }
  return (
    <LockedShell>
      <div className="mx-auto w-full max-w-[938px] py-4 sm:py-8">
        <div className="mb-9 sm:mb-11">
          <div className="h-1 w-full overflow-hidden rounded-full bg-muted">
            <div className="h-full w-[10%] rounded-full bg-brand" />
          </div>
        </div>
        <div className={styles.reveal}>
          <h1 className="max-w-[600px] text-balance text-[clamp(1.85rem,3.2vw,2.4rem)] font-normal leading-[1.14] tracking-[-0.03em]">
            <span className="text-muted-foreground">{t(copy.headlineMuted)}</span>
            <br />
            <span className="text-foreground">{t(copy.headlineActive)}</span>
          </h1>
          <p className="mt-6 max-w-[520px] text-[15px] leading-6 text-muted-foreground">{t(copy.note)}</p>
          <button
            className="mt-9 inline-flex min-h-12 items-center justify-center rounded-full bg-brand px-7 text-[15px] font-normal text-brand-foreground shadow-elev-1 transition-colors hover:bg-brand/90"
            onClick={() => window.location.reload()}
            type="button"
          >
            {t("Retry")}
          </button>
        </div>
      </div>
    </LockedShell>
  )
}

/**
 * Open routes (see `requiresOnboarding`) render for everyone. The dashboard and umbrella stay
 * inside the gate until Convex confirms the wallet finished onboarding.
 */
export function SandboxGate({
  children,
  onboardedWallet,
}: {
  children: ReactNode
  /** Wallet named by the `avana_onboarded` cookie (root layout), if it matches the session wallet. */
  onboardedWallet?: string
}) {
  const pathname = usePathname()
  const { authedWallet, isSignedIn } = useSiweAuth()
  // Ask AI is public for guests (knowledge / markets without a wallet). Signed-in
  // users keep the normal AuthedGate mounted so closing Ask doesn't tear down the
  // product shell and flash a blank screen while Convex/session rehydrate.
  const isAskRoute = pathname === "/ask" || pathname.startsWith("/ask/")
  if (isAskRoute && !isSignedIn) return <>{children}</>
  if (IS_DEV_SHORTCUT_MODE) return <>{children}</>
  if (!hasConvexClient) return <GateUnavailable variant="offline" />
  // Guests browse every open route with live, unauthenticated market data; the action CTA
  // (not this gate) sends them to onboarding when they try to transact.
  if (!isSignedIn && !requiresOnboarding(pathname))
    return <TransactAccessContext.Provider value="guest">{children}</TransactAccessContext.Provider>
  // The SIWE store's server/hydration snapshot is seeded from the verified `avana_siwe` cookie
  // (root layout), so `isSignedIn` is truthful during SSR and the first client render: guests get the onboarding hero server-rendered (fast LCP, nothing to flash), and
  // signed-in users never pass through a signed-out frame.
  if (!isSignedIn || !authedWallet) {
    return (
      <LockedShell>
        <GuestOnboardingFlow />
      </LockedShell>
    )
  }
  return (
    <SignedInSandboxGate key={authedWallet} wallet={authedWallet} optimistic={onboardedWallet === authedWallet}>
      {children}
    </SignedInSandboxGate>
  )
}
