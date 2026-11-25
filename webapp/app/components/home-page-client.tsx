"use client"

import dynamic from "next/dynamic"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { shouldUseOpenGateSession } from "@/app/lib/test-mode"
import { HomePageGuestWorkspace } from "./home-page-guest-workspace"

// Signed-in and development sessions come from the layout. The guest's initial
// swap uses its own empty session without downloading the other product engines.
const HomePageWorkspaceRuntime = dynamic(() =>
  import("@/app/components/home-page-workspace-runtime").then((mod) => ({
    default: mod.HomePageWorkspaceRuntime,
  })),
)

export function HomePageClient() {
  const { isSignedIn } = useSiweAuth()
  if (!isSignedIn && !shouldUseOpenGateSession()) return <HomePageGuestWorkspace />
  return <HomePageWorkspaceRuntime />
}
