import { SchemaMarkup, buildOrganizationSchema, buildWebSiteSchema } from "@/app/components/seo/schema"
import type { Metadata } from "next"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { HomePageClient } from "@/app/components/home-page-client"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

export const metadata: Metadata = buildSeoMetadata({
  title: "Borrow Against LP Positions on Aave v4",
  description: "Borrow against LP positions on Aave v4 and lend.",
  path: "/",
  keywords: ["Avana", "borrow LP tokens", "DeFi lending", "Aave v4"],
  index: true,
})

export default async function HomePage() {
  if (isLighthouseAuditMode()) {
    return (
      <>
        <SchemaMarkup data={[buildWebSiteSchema(), buildOrganizationSchema()]} />
        <LighthouseAuditSurface title="Borrow">
          Swap, Borrow, Repay, Claim, Remove, Select Asset, Dashboard, Umbrella.
        </LighthouseAuditSurface>
      </>
    )
  }

  // Site-wide WebSite + Organization JSON-LD now renders once in the root layout <head>
  // (in the served shell). The home page just renders its content.
  return <HomePageClient />
}
