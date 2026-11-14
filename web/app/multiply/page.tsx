import type { Metadata } from "next"
import { SchemaMarkup, buildWebPageSchema } from "@/app/components/seo/schema"
import { fetchMultiplyPage } from "@/app/lib/data/providers/multiply"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

export const metadata: Metadata = buildSeoMetadata({
  title: "Multiply",
  description: "Multiply LP-backed positions.",
  path: "/multiply",
  index: true,
  keywords: ["multiply LP positions", "leveraged DeFi", "looping strategies", "Aave v4"],
})

export default async function MultiplyPage() {
  if (isLighthouseAuditMode()) {
    return (
      <>
        <SchemaMarkup
          data={buildWebPageSchema({
            name: "Multiply",
            description: "Multiply LP-backed positions.",
            url: `${SITE_URL}/multiply`,
          })}
        />
        <LighthouseAuditSurface title="Multiply TVL">Multiply LP-backed positions.</LighthouseAuditSurface>
      </>
    )
  }

  const [pageData, { MultiplyClient }] = await Promise.all([fetchMultiplyPage(), import("./multiply-client")])

  return (
    <>
      <SchemaMarkup
        data={buildWebPageSchema({
          name: "Multiply",
          description: "Multiply LP-backed positions.",
          url: `${SITE_URL}/multiply`,
        })}
      />
      <MultiplyClient pageData={pageData} />
    </>
  )
}
