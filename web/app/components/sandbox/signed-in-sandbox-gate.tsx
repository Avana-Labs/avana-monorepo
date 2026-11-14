"use client"

import { Component, Suspense, useState, type ReactNode } from "react"
import { usePathname } from "next/navigation"
import { RouteContentSkeleton } from "@/app/components/loading-states"
import { SiweConvexProvider } from "@/app/lib/convex/siwe-convex-provider"
import { requiresOnboarding } from "@/app/lib/route-access"
import { TransactAccessContext } from "@/app/lib/transact-access"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { AuthedGateChecker, type GateVerdict } from "./authed-sandbox-gate"
import styles from "./onboarding-flow.module.css"

function LockedShell({ children }: { children: ReactNode }) {
  return <main className="flex flex-1 px-5 py-6 sm:px-8">{children}</main>
}

function SignedGateError() {
  const { t } = useTranslation()
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
            <span className="text-muted-foreground">{t("Something went wrong.")}</span>
            <br />
            <span className="text-foreground">{t("We couldn't load this page.")}</span>
          </h1>
          <p className="mt-6 max-w-[520px] text-[15px] leading-6 text-muted-foreground">
            {t("This is on our side, not your wallet. Try again, and let us know if it keeps happening.")}
          </p>
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

class GateErrorBoundary extends Component<{ children: ReactNode }, { errored: boolean }> {
  state = { errored: false }
  static getDerivedStateFromError() {
    return { errored: true }
  }
  render() {
    return this.state.errored ? <SignedGateError /> : <>{this.props.children}</>
  }
}

/** Convex-backed gate loaded only for a server-verified or newly signed-in wallet. */
export function SignedInSandboxGate({
  wallet,
  optimistic,
  children,
}: {
  wallet: string
  optimistic: boolean
  children: ReactNode
}) {
  const pathname = usePathname()
  const [verdict, setVerdict] = useState<GateVerdict>("unknown")
  // Open routes stay mounted whatever the verdict; only onboarding routes wait for "done".
  const showChildren = !requiresOnboarding(pathname) || verdict === "done" || (verdict === "unknown" && optimistic)

  return (
    <GateErrorBoundary>
      <SiweConvexProvider>
        <TransactAccessContext.Provider value={verdict === "blocked" ? "needs-onboarding" : "ready"}>
          {showChildren ? children : verdict === "unknown" ? <RouteContentSkeleton /> : null}
        </TransactAccessContext.Provider>
        <Suspense fallback={null}>
          <AuthedGateChecker wallet={wallet} optimistic={optimistic} onVerdict={setVerdict} />
        </Suspense>
      </SiweConvexProvider>
    </GateErrorBoundary>
  )
}
