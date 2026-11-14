"use client"

import { createContext, useContext, type MouseEvent } from "react"
import { useGetStarted } from "@/app/lib/web3/get-started-intent"

/**
 * Whether the viewer may submit a transaction. The sandbox gate provides it: guests browse open
 * routes, and a signed-in wallet must finish onboarding (on the dashboard) before transacting.
 * Defaults to "ready" outside the gate (dev open gate, tests).
 */
export type TransactAccess = "ready" | "guest" | "needs-onboarding"

export const TransactAccessContext = createContext<TransactAccess>("ready")

export function useTransactAccess() {
  return useContext(TransactAccessContext)
}

/** Where a blocked primary CTA sends a signed-in wallet: the dashboard's onboarding flow. */
export const TRANSACT_ACCESS_HREF = "/dashboard"

/** Primary CTA label for a viewer who cannot transact yet, or null when they can. */
export function transactAccessCtaLabel(access: TransactAccess) {
  if (access === "guest") return "Get Started"
  if (access === "needs-onboarding") return "Complete onboarding"
  return null
}

/**
 * A blocked primary CTA: its label, and for a guest a click handler that runs the same Get
 * Started flow as the header (connect, then onboarding only if the wallet needs it) instead of
 * following the dashboard link. Put `onClick` on the link (or pass it as the footer's
 * `onPrimary`); a wallet still onboarding keeps the plain dashboard link.
 */
export function useTransactAccessCta() {
  const access = useTransactAccess()
  const getStarted = useGetStarted()
  const label = transactAccessCtaLabel(access)
  const onGuestClick =
    access === "guest"
      ? (event?: MouseEvent) => {
          event?.preventDefault()
          getStarted()
        }
      : undefined
  return { label, href: TRANSACT_ACCESS_HREF, onClick: onGuestClick }
}
