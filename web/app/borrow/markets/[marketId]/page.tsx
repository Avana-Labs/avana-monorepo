import { notFound } from "next/navigation"
import type { Metadata } from "next"
import { SchemaMarkup, buildBreadcrumbSchema, buildFaqSchema, buildWebPageSchema } from "@/app/components/seo/schema"
import { applyPoolPreloadedOverlays, getPoolDetailFromConvex } from "@/app/lib/borrow-detail/convex-detail"
import { preloadPoolHero } from "@/app/lib/borrow-detail/hero-preload"
import { preloadDetailQuickStats } from "@/app/lib/detail-page/quick-stats-preload"
import { preloadDetailCashflow } from "@/app/lib/detail-page/cashflow-preload"
import { readPreloadedCashflow, readPreloadedQuickStats } from "@/app/lib/detail-page/apply-preloaded-overlays"
import { BorrowMarketDetailClientShell } from "./page-client-shell"
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
      title: "Market · Avana Borrow",
      description: "Explore borrow market details, supported collateral, and available liquidity on Avana.",
      path: `/borrow/markets/${marketId}`,
      keywords: ["LP collateral", "borrow against AMM positions"],
    })
  const detail = await getPoolDetailFromConvex(marketId)
  if (!detail)
    return {
      title: "Market · Avana",
      description: "Explore borrow market details, supported collateral, and available liquidity on Avana.",
    }
  return buildSeoMetadata({
    title: `${detail.hero.name} · Avana Borrow`,
    description: detail.about.description,
    path: `/borrow/markets/${marketId}`,
    index: true,
    keywords: [detail.hero.name, "LP collateral", "borrow against AMM positions"],
  })
}

export default async function MarketDetailPage({ params }: PageProps) {
  const { marketId } = await params
  if (isLighthouseAuditMode()) return <LighthouseAuditSurface title="Total supplied" eyebrow={marketId} />

  const detailPromise = getPoolDetailFromConvex(marketId)
  const [{ feeds }, quickStatsPreload, cashflowPreload, detailRaw] = await Promise.all([
    preloadPoolHero(marketId),
    preloadDetailQuickStats("pool", marketId),
    preloadDetailCashflow("pool", marketId),
    detailPromise,
  ])
  if (!detailRaw) notFound()
  const detail = applyPoolPreloadedOverlays(detailRaw, {
    quickStats: readPreloadedQuickStats(quickStatsPreload),
    cashflow: readPreloadedCashflow(cashflowPreload),
  })
  const detailWithFeeds = { ...detail, ...feeds }
  const canonicalUrl = `${SITE_URL}/borrow/markets/${marketId}`
  return (
    <>
      <SchemaMarkup
        data={[
          buildWebPageSchema({
            name: `${detail.hero.name} · Avana Borrow`,
            description: detail.about.description,
            url: canonicalUrl,
          }),
          buildBreadcrumbSchema([
            { name: "Home", url: SITE_URL },
            { name: "Borrow", url: `${SITE_URL}/borrow` },
            { name: detail.hero.name, url: canonicalUrl },
          ]),
          buildFaqSchema(detail.faqs.map((faq) => ({ question: faq.question, answer: faq.answer }))),
        ]}
      />
      <BorrowMarketDetailClientShell detail={detailWithFeeds} />
    </>
  )
}
