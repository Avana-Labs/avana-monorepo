"use client"

import { createContext, useContext, type MouseEvent } from "react"
import { useGetStarted } from "@/app/lib/web3/get-started-intent"

/**
 * Whether the viewer may submit a transaction. `TransactAccessProvider` sets it: every route is
 * open, and a guest is asked to connect a wallet before transacting. Defaults to "ready" outside
 * the provider (dev open gate, tests).
 */
export type TransactAccess = "ready" | "guest"

export const TransactAccessContext = createContext<TransactAccess>("ready")

export function useTransactAccess() {
  return useContext(TransactAccessContext)
}

/** Fallback link of a blocked primary CTA. */
export const TRANSACT_ACCESS_HREF = "/dashboard"

/** Primary CTA label for a viewer who cannot transact yet, or null when they can. */
export function transactAccessCtaLabel(access: TransactAccess) {
  if (access === "guest") return "Get Started"
  return null
}

/**
 * A blocked primary CTA: its label, and for a guest a click handler that runs the same Get
 * Started flow as the header (connect the wallet) instead of following the link. Put `onClick`
 * on the link (or pass it as the footer's `onPrimary`).
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
