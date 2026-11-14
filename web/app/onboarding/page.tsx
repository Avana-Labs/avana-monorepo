import type { Metadata } from "next"
import { SchemaMarkup, buildWebPageSchema } from "@/app/components/seo/schema"
import { OnboardingPageClient } from "./onboarding-page-client"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"

export const metadata: Metadata = buildSeoMetadata({
  title: "Onboarding",
  description: "Connect a wallet and claim your simulated Avana sandbox allocation.",
  path: "/onboarding",
  keywords: ["Avana onboarding", "wallet connect", "sandbox allocation", "DeFi walkthrough"],
})

/**
 * Live onboarding entry. Screens live in `OnboardingFlow`
 * (`app/components/sandbox/onboarding-flow.tsx`) and advance from Convex
 * `sandboxProfiles.onboardingStep` (+ client-only personalize/DEX sub-steps).
 *
 * To spin up another throwaway step-jumper later: add a short-lived route that
 * renders `<OnboardingFlow>` with a forced phase / mock `OnboardingGateState`,
 * and pass that path through `SandboxGate` / `AuthedSandboxGate` like `/ask`
 * so the gate does not replace the page. Delete the route when the review is done.
 */
export default function OnboardingPage() {
  return (
    <>
      <SchemaMarkup
        data={buildWebPageSchema({
          name: "Onboarding",
          description: "Connect a wallet and claim your simulated Avana sandbox allocation.",
          url: `${SITE_URL}/onboarding`,
        })}
      />
      <OnboardingPageClient />
    </>
  )
}
