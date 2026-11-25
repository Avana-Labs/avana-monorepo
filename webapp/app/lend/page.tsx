import type { Metadata } from "next"
import { SchemaMarkup, buildWebPageSchema } from "@/app/components/seo/schema"
import { fetchLendPage } from "@/app/lib/data/providers/lend"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { SITE_URL } from "@/app/lib/site-url"
import { LighthouseAuditSurface } from "@/app/components/lighthouse-audit-surface"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"

export const metadata: Metadata = buildSeoMetadata({
  title: "Lend",
  description: "Supply assets to the protocol and earn yield.",
  path: "/lend",
  index: true,
  keywords: ["lend crypto", "supply assets", "earn yield", "DeFi lending"],
})

export default async function LendPage() {
  if (isLighthouseAuditMode()) {
    return (
      <>
        <SchemaMarkup
          data={buildWebPageSchema({
            name: "Lend",
            description: "Supply assets to the protocol and earn yield.",
            url: `${SITE_URL}/lend`,
          })}
        />
        <LighthouseAuditSurface title="Lend TVL">Lend assets and supply markets.</LighthouseAuditSurface>
      </>
    )
  }

  const [pageData, { LendClient }] = await Promise.all([fetchLendPage(), import("./lend-client")])

  return (
    <>
      <SchemaMarkup
        data={buildWebPageSchema({
          name: "Lend",
          description: "Supply assets to the protocol and earn yield.",
          url: `${SITE_URL}/lend`,
        })}
      />
      <LendClient pageData={pageData} />
    </>
  )
}
