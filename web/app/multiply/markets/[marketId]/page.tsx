import type { Metadata } from "next"
import { notFound } from "next/navigation"
import { SchemaMarkup, buildBreadcrumbSchema, buildFaqSchema, buildWebPageSchema } from "@/app/components/seo/schema"
import { getMultiplyMarketDetail } from "@/app/lib/multiply-detail"
import {
  applyMultiplyPreloadedOverlays,
  getMultiplyMarketDetailFromConvex,
} from "@/app/lib/multiply-detail/convex-detail"
import { preloadMultiplyHero } from "@/app/lib/multiply-detail/hero-preload"
import { preloadDetailQuickStats } from "@/app/lib/detail-page/quick-stats-preload"
import { preloadDetailCashflow } from "@/app/lib/detail-page/cashflow-preload"
import { readPreloadedCashflow, readPreloadedQuickStats } from "@/app/lib/detail-page/apply-preloaded-overlays"
import { MultiplyMarketDetailClientShell } from "./page-client-shell"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

type PageProps = {
  params: Promise<{ marketId: string }>
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { marketId } = await params
  // Audit build has no live backend: resolve metadata statically so the description lands in the
  // initial <head> for Lighthouse instead of streaming in late.
  if (isLighthouseAuditMode())
    return buildSeoMetadata({
      title: "Multiply market · Avana",
      description: "Explore multiply market details, leverage strategies, and total value locked on Avana.",
      path: `/multiply/markets/${marketId}`,
      keywords: ["leveraged LP strategy", "multiply market"],
    })
  const detail = getMultiplyMarketDetail(marketId)
  if (!detail)
    return {
      title: "Multiply market · Avana",
      description: "Explore multiply market details, leverage strategies, and total value locked on Avana.",
    }
  return buildSeoMetadata({
    title: `${detail.hero.name} · Avana Multiply`,
    description: detail.about.description,
    path: `/multiply/markets/${marketId}`,
    index: true,
    keywords: [detail.hero.name, "leveraged LP strategy", "multiply market"],
  })
}

export default async function MarketDetailPage({ params }: PageProps) {
  const { marketId } = await params
  if (isLighthouseAuditMode()) return <LighthouseAuditSurface title="Total value locked" eyebrow={marketId} />

  const [detailRaw, heroBundle, quickStatsPreload, cashflowPreload] = await Promise.all([
    getMultiplyMarketDetailFromConvex(marketId),
    preloadMultiplyHero(marketId),
    preloadDetailQuickStats("multiply", marketId),
    preloadDetailCashflow("multiply", marketId),
  ])
  if (!detailRaw) notFound()
  const detail = applyMultiplyPreloadedOverlays(detailRaw, {
    quickStats: readPreloadedQuickStats(quickStatsPreload),
    cashflow: readPreloadedCashflow(cashflowPreload),
    baselinePriceSymbol: detailRaw.row.protocol,
  })
  const { feeds } = heroBundle
  const detailWithFeeds = { ...detail, ...feeds }
  const canonicalUrl = `${SITE_URL}/multiply/markets/${marketId}`
  return (
    <>
      <SchemaMarkup
        data={[
          buildWebPageSchema({
            name: `${detail.hero.name} · Avana Multiply`,
            description: detail.about.description,
            url: canonicalUrl,
          }),
          buildBreadcrumbSchema([
            { name: "Home", url: SITE_URL },
            { name: "Multiply", url: `${SITE_URL}/multiply` },
            { name: detail.hero.name, url: canonicalUrl },
          ]),
          buildFaqSchema(detail.faqs.map((faq) => ({ question: faq.question, answer: faq.answer }))),
        ]}
      />
      <MultiplyMarketDetailClientShell detail={detailWithFeeds} />
    </>
  )
}
