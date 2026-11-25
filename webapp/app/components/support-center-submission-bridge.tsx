"use client"

import { lazy, Suspense } from "react"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import type { SupportSubmit } from "./support-center-client"

const ConvexSupportSubmissionBridge = lazy(async () => ({
  default: (await import("./support-center-connected")).ConvexSupportSubmissionBridge,
}))

export function SupportCenterSubmissionBridge({ onReady }: { onReady: (submit: SupportSubmit | null) => void }) {
  const { authedWallet, isSignedIn } = useSiweAuth()
  if (!hasConvexClient || !isSignedIn || !authedWallet) return null
  return (
    <Suspense fallback={null}>
      <ConvexSupportSubmissionBridge onReady={onReady} />
    </Suspense>
  )
}
