"use client"

import { useEffect } from "react"
import { OnboardingUnavailable } from "@/app/components/sandbox/onboarding-flow"

/**
 * Route-level boundary for /onboarding. A JWT-gated Convex query on this page can throw
 * UNAUTHENTICATED (e.g. the token lapses between render and query); without this it would
 * fall through to the generic framework error page. Render the graceful signed-out prompt
 * instead — `reset()` re-attempts the segment once the user reconnects.
 */
export default function OnboardingError({ error, reset }: { error: Error; reset: () => void }) {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") console.error(error)
  }, [error])

  const isAuth = /UNAUTHENTICATED|WALLET_MISMATCH|Not authenticated/i.test(error.message)
  return (
    <main className="min-h-[calc(100vh-4rem)] px-5 py-6 sm:px-8">
      <OnboardingUnavailable
        onRetry={reset}
        headlineMuted={isAuth ? "Your session needs a refresh." : "Something went wrong."}
        headlineActive={isAuth ? "Reconnect your wallet to continue onboarding." : "We couldn't load onboarding."}
        note={
          isAuth
            ? "Authenticated sessions stay locked until Convex confirms access."
            : "This is on our side, not your wallet. Try again, and let us know if it keeps happening."
        }
      />
    </main>
  )
}
