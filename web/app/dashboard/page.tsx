import type { Metadata } from "next"
import { SchemaMarkup, buildWebPageSchema } from "@/app/components/seo/schema"
import { fetchRewardsPage } from "@/app/lib/data/providers/rewards"
import { resolvePortfolioWalletProfileId } from "@/app/lib/data/providers/portfolio"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

export const metadata: Metadata = buildSeoMetadata({
  title: "Dashboard",
  description: "Track your accounts, positions, quest progress, and activity across Avana.",
  path: "/dashboard",
  keywords: ["Avana dashboard", "positions", "quests", "activity", "rewards"],
})

const DASHBOARD_SCHEMA = buildWebPageSchema({
  name: "Dashboard",
  description: "Track your accounts, positions, quest progress, and activity across Avana.",
  url: `${SITE_URL}/dashboard`,
})

export default async function DashboardPage() {
  if (isLighthouseAuditMode()) {
    return (
      <>
        <SchemaMarkup data={DASHBOARD_SCHEMA} />
        <LighthouseAuditSurface title="Dashboard">Track your accounts and positions.</LighthouseAuditSurface>
      </>
    )
  }

  if (resolveDataSourceMode() === "live") {
    const { DashboardPageClient } = await import("@/app/dashboard/dashboard-page-client")

    return (
      <>
        <SchemaMarkup data={DASHBOARD_SCHEMA} />
        <div className="bg-background">
          <main className="container mx-auto px-3 py-6 sm:px-4 md:py-10">
            <h1 className="sr-only">Dashboard</h1>
            <div className="mx-auto max-w-[1152px]">
              <DashboardPageClient />
            </div>
          </main>
        </div>
      </>
    )
  }
  const walletProfileId = await resolvePortfolioWalletProfileId()
  const pageData = await fetchRewardsPage({ walletProfileId })
  const { DashboardPageClient } = await import("@/app/dashboard/dashboard-page-client")

  return (
    <>
      <SchemaMarkup data={DASHBOARD_SCHEMA} />
      <div className="bg-background">
        <main className="container mx-auto px-3 py-6 sm:px-4 md:py-10">
          <div className="mx-auto max-w-[1152px]">
            <DashboardPageClient pageData={pageData} />
          </div>
        </main>
      </div>
    </>
  )
}
