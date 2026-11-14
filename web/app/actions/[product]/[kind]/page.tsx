import { ActionPageClient } from "@/app/components/action-page/action-page-client"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import type { ActionKind, ActionProduct } from "@/app/lib/action-system/contracts"
import { isValidAction, normalizeActionKind, resolveActionCloseHref } from "@/app/lib/action-system/contracts"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"
import type { Metadata } from "next"
import { notFound } from "next/navigation"

type PageProps = {
  params: Promise<{ product: ActionProduct; kind: ActionKind }>
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

function readParam(value: string | string[] | undefined) {
  return typeof value === "string" ? value : undefined
}

const ACTION_TITLES: Record<ActionProduct, Partial<Record<ActionKind, string>>> = {
  borrow: {
    borrow: "Borrow",
    repay: "Repay",
    supply: "Pledge collateral",
    remove: "Remove collateral",
    claim: "Claim fees",
  },
  lend: {
    deposit: "Lend deposit",
    withdraw: "Lend withdraw",
  },
  rewards: {
    claim: "Claim rewards",
  },
  umbrella: {
    stake: "Umbrella stake",
    unstake: "Umbrella unstake",
    claim: "Claim Umbrella rewards",
    cooldown: "Umbrella cooldown",
  },
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { product, kind } = await params
  if (!isValidAction(product, kind)) {
    // Invalid routes 404 in the page; keep the tab title static instead of echoing
    // the raw URL segments (the old `${product} ${kind}` fallback).
    return buildSeoMetadata({
      title: "Action unavailable",
      description: "This action is not available on Avana.",
      path: `/actions/${product}/${kind}`,
    })
  }
  const title = ACTION_TITLES[product]?.[normalizeActionKind(product, kind)] ?? "Action"
  return buildSeoMetadata({
    title,
    description: `Complete your ${title.toLowerCase()} transaction on Avana.`,
    path: `/actions/${product}/${kind}`,
  })
}

export default async function ActionPage({ params, searchParams }: PageProps) {
  const { product, kind } = await params
  // Unknown product/kind is a real 404, not a soft 200 with an <ActionNotFound> body.
  if (!isValidAction(product, kind)) {
    notFound()
  }
  const query = await searchParams

  if (isLighthouseAuditMode()) {
    return <LighthouseAuditSurface title={kind} eyebrow={product} />
  }

  return (
    <ActionPageClient
      product={product}
      kind={kind}
      closeHref={resolveActionCloseHref(product, readParam(query.return))}
      initialAssetId={readParam(query.asset)}
      initialMarketId={readParam(query.market)}
      initialAmount={readParam(query.amount)}
      initialPositionId={readParam(query.position)}
      initialDebtId={readParam(query.debt)}
    />
  )
}
