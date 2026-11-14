"use client"

import type { ReactNode } from "react"
import { useMediaQuery } from "@/app/lib/use-media-query"
import { ActionPageLaunchCta } from "@/app/components/action-page/action-page-launch-cta"
import { DetailSidebarActionCard } from "@/app/components/action-page/detail-sidebar-action-card"
import type { ActionKind, ActionProduct } from "@/app/lib/action-system/contracts"

/**
 * Shared shell for the detail-page action rail (borrow / lend / multiply).
 *
 * Desktop: render the embedded, pre-loaded product action (`children`) — wrapped
 * in the sidebar card when `sidebar`. Mobile: fall through to a launch CTA that
 * navigates to the full-screen /actions page instead of force-embedding the full
 * widget inline (which overflowed the mobile dock and clipped the CTA).
 *
 * Each product wrapper stays thin: it only knows which client to mount and which
 * initial props to pass; the responsive + sidebar plumbing lives here once.
 */
export function ResponsiveDetailAction({
  product,
  kind,
  market,
  asset,
  amount,
  closeHref,
  label,
  sidebar = false,
  children,
}: {
  product: ActionProduct
  kind: ActionKind
  market?: string
  asset?: string
  amount?: string
  closeHref: string
  label?: string
  sidebar?: boolean
  children: ReactNode
}) {
  // Hydrate from the server-selected default (desktop) on the first client
  // render, then reconcile the real media query in an effect — otherwise the
  // first client render reads the live viewport and diverges from SSR, which
  // hydration-mismatches the action rail (embedded card vs launch CTA).
  const isDesktop = useMediaQuery("(min-width: 768px)", true, true)

  if (!isDesktop) {
    return (
      <ActionPageLaunchCta
        product={product}
        kind={kind}
        market={market}
        asset={asset}
        amount={amount}
        returnTo={closeHref}
        label={label}
      />
    )
  }

  return sidebar ? <DetailSidebarActionCard>{children}</DetailSidebarActionCard> : <>{children}</>
}
