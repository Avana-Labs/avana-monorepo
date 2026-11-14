"use client"

import { MultiplyActionPageClient } from "@/app/components/action-page/multiply-action-page-client"
import { ResponsiveDetailAction } from "@/app/components/action-page/responsive-detail-action"
import type { MultiplyActionKind } from "@/app/lib/action-system/contracts"

export function ResponsiveMultiplyAction({
  kind,
  market,
  closeHref,
  label,
  sidebar = false,
  initialMultiplier,
}: {
  kind: MultiplyActionKind
  market: string
  closeHref: string
  label?: string
  sidebar?: boolean
  initialMultiplier?: string
}) {
  return (
    <ResponsiveDetailAction
      product="multiply"
      kind={kind}
      market={market}
      closeHref={closeHref}
      label={label}
      sidebar={sidebar}
    >
      <MultiplyActionPageClient
        kind={kind}
        embedded
        sidebar={sidebar}
        layout="default"
        closeHref={closeHref}
        initialMarketId={market}
        initialMultiplier={initialMultiplier}
      />
    </ResponsiveDetailAction>
  )
}
