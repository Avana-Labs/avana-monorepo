import type { Metadata } from "next"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"
import { SwapPageClient } from "./swap-page-client"

export const metadata: Metadata = buildSeoMetadata({
  title: "Swap",
  description: "Swap assets on Avana.",
  path: "/swap",
  keywords: ["swap crypto", "token swap", "exchange assets", "Avana swap"],
})

type SwapPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

function readParam(value: string | string[] | undefined) {
  return typeof value === "string" ? value : undefined
}

function safeReturnHref(value: string | undefined) {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return "/"
  return value
}

export default async function SwapPage({ searchParams }: SwapPageProps) {
  // In the Lighthouse audit build the client session provider is not mounted
  // server-side (AvanaSessionProviders is ssr:false), so rendering SwapPageClient —
  // which calls useSwapSessionContext — throws during SSR. Every other product page
  // renders a static audit surface in this mode; do the same here.
  if (isLighthouseAuditMode()) {
    return <LighthouseAuditSurface title="Swap">Swap assets on Avana.</LighthouseAuditSurface>
  }

  const query = await searchParams
  return (
    <main className="min-h-[calc(100dvh-4rem)]">
      <SwapPageClient
        initialFrom={readParam(query.from)}
        initialTo={readParam(query.to)}
        origin={readParam(query.origin)}
        returnHref={safeReturnHref(readParam(query.return))}
      />
    </main>
  )
}
