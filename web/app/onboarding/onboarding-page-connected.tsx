"use client"

import { useEffect } from "react"
import { useRouter } from "next/navigation"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { RouteContentSkeleton } from "@/app/components/loading-states"
import { OnboardingFlow, type OnboardingGateState } from "@/app/components/sandbox/onboarding-flow"

export function OnboardingPageConnected({ wallet }: { wallet: string }) {
  const router = useRouter()
  const gate = useQuery(api.sandbox.onboarding.getOnboardingGateState, { wallet }) as
    (OnboardingGateState & { economy: OnboardingGateState["economy"] | null }) | undefined
  const isDone = gate?.onboardingStep === "done"

  useEffect(() => {
    if (isDone) router.replace("/dashboard")
  }, [isDone, router])
  // Don't flash the onboarding flow before we know the wallet's state: an
  // already-onboarded wallet hitting /onboarding directly should go straight to
  // the redirect, never briefly re-see onboarding while the query resolves. (#42)
  if (gate === undefined || isDone) return isDone ? null : <RouteContentSkeleton />
  if (!gate.economy) return <RouteContentSkeleton />

  return <OnboardingFlow wallet={wallet} state={{ ...gate, economy: gate.economy }} />
}
