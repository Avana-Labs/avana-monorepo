"use client"

import type { ReactNode } from "react"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { pendingUmbrellaPersistAction } from "@/app/lib/umbrella-system/use-umbrella-session"

/** Convex-backed Instant Paint shell — zeros wallet metrics until remote session data arrives. */
export function PendingConvexSessionProvider({ walletId, children }: { walletId: string; children: ReactNode }) {
  return (
    <AvanaSessionsProvider
      walletId={walletId}
      persistLocalState={false}
      persistUmbrellaState={false}
      sessionSource="convex"
      authoritativeWalletPending
      persistUmbrellaAction={pendingUmbrellaPersistAction}
    >
      {children}
    </AvanaSessionsProvider>
  )
}
