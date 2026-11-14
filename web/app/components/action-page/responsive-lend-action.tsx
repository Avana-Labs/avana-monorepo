"use client"

import { LendActionPageClient } from "@/app/components/action-page/lend-action-page-client"
import { ResponsiveDetailAction } from "@/app/components/action-page/responsive-detail-action"

export function ResponsiveLendAction({
  kind,
  market,
  closeHref,
  label,
  sidebar = false,
}: {
  kind: "deposit" | "withdraw"
  market: string
  closeHref: string
  label?: string
  sidebar?: boolean
}) {
  return (
    <ResponsiveDetailAction
      product="lend"
      kind={kind}
      market={market}
      closeHref={closeHref}
      label={label}
      sidebar={sidebar}
    >
      <LendActionPageClient
        kind={kind}
        embedded
        sidebar={sidebar}
        layout="default"
        closeHref={closeHref}
        initialMarketId={market}
      />
    </ResponsiveDetailAction>
  )
}
