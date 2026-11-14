import { notFound } from "next/navigation"
import type { Metadata } from "next"
import { SchemaMarkup, buildBreadcrumbSchema, buildFaqSchema, buildWebPageSchema } from "@/app/components/seo/schema"
import { getAssetDetail } from "@/app/lib/borrow-detail"
import { applyAssetPreloadedOverlays, getAssetDetailFromConvex } from "@/app/lib/borrow-detail/convex-detail"
import { resolveSpokeBorrowable } from "@/app/lib/borrow-system/registry"
import { normalizeBorrowAssetRouteId } from "@/app/lib/borrow-routes"
import { preloadAssetHero } from "@/app/lib/borrow-detail/hero-preload"
import { preloadDetailQuickStats } from "@/app/lib/detail-page/quick-stats-preload"
import { preloadDetailCashflow } from "@/app/lib/detail-page/cashflow-preload"
import { readPreloadedCashflow, readPreloadedQuickStats } from "@/app/lib/detail-page/apply-preloaded-overlays"
import { AssetDetailClient } from "@/app/borrow/assets/[assetId]/asset-detail-client"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

type PageProps = {
  params: Promise<{ assetId: string }>
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { assetId } = await params
  // Audit build has no live backend: resolve metadata statically (no async data fetch) so the
  // description lands in the initial <head> for Lighthouse instead of streaming in late.
  if (isLighthouseAuditMode())
    return buildSeoMetadata({
      title: "Asset · Avana Borrow",
      description: "View asset details, borrow rates, and supply data on Avana.",
      path: `/borrow/assets/${assetId}`,
      keywords: ["borrow against LP tokens"],
    })
  const detail = getAssetDetail(assetId)
  if (!detail)
    return { title: "Asset · Avana", description: "View asset details, borrow rates, and supply data on Avana." }
  return buildSeoMetadata({
    title: `${detail.hero.symbol} · Avana Borrow`,
    description: detail.about.description,
    path: `/borrow/assets/${assetId}`,
    index: true,
    keywords: [detail.hero.symbol, detail.hero.name, "borrow against LP tokens"],
  })
}

export default async function BorrowAssetPage({ params }: PageProps) {
  const { assetId } = await params
  if (isLighthouseAuditMode()) return <LighthouseAuditSurface title="Asset data" eyebrow={assetId} />

  // Resolve spoke slug before fan-out so hero/QS/cashflow hit the same Convex keys as the builder.
  // (BASE ids like "dai" must map to spoke-scoped "uni-v2:dai" — D2.)
  const canonicalSlug = resolveSpokeBorrowable(normalizeBorrowAssetRouteId(assetId))?.id ?? assetId
  const [detailRawConvex, heroBundle, quickStatsPreload, cashflowPreload] = await Promise.all([
    getAssetDetailFromConvex(assetId),
    preloadAssetHero(canonicalSlug),
    preloadDetailQuickStats("asset", canonicalSlug),
    preloadDetailCashflow("asset", canonicalSlug),
  ])
  // Fail closed like the pool / lend / multiply detail routes: getAssetDetailFromConvex
  // already returns null in live mode when Convex has no snapshot, so honor that with a
  // notFound() instead of swapping the whole mock catalog detail back in. (Mock mode
  // returns a catalog-built detail here, so the demo/Playwright routes still render.)
  if (!detailRawConvex) notFound()
  const detailBase = detailRawConvex
  const spoke = resolveSpokeBorrowable(normalizeBorrowAssetRouteId(assetId))
  const detail = applyAssetPreloadedOverlays(detailBase, {
    quickStats: readPreloadedQuickStats(quickStatsPreload),
    cashflow: readPreloadedCashflow(cashflowPreload),
    baselinePriceSymbol: spoke?.baseAssetId ?? detailBase.hero.symbol,
  })
  const { feeds } = heroBundle
  const detailWithFeeds = { ...detail, ...feeds }
  const canonicalUrl = `${SITE_URL}/borrow/assets/${assetId}`
  return (
    <>
      <SchemaMarkup
        data={[
          buildWebPageSchema({
            name: `${detail.hero.symbol} · Avana Borrow`,
            description: detail.about.description,
            url: canonicalUrl,
          }),
          buildBreadcrumbSchema([
            { name: "Home", url: SITE_URL },
            { name: "Borrow", url: `${SITE_URL}/borrow` },
            { name: detail.hero.symbol, url: canonicalUrl },
          ]),
          buildFaqSchema(detail.faqs.map((faq) => ({ question: faq.question, answer: faq.answer }))),
        ]}
      />
      <AssetDetailClient detail={detailWithFeeds} />
    </>
  )
}
