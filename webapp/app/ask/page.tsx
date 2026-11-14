import type { Metadata } from "next"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import { AskPageClient } from "./ask-page-client"

export const metadata: Metadata = buildSeoMetadata({
  title: "Ask AI",
  description: "Ask Avana about LP collateral, borrowing capacity, supported markets, and position risk.",
  path: "/ask",
  keywords: ["Avana Ask AI", "DeFi assistant", "LP collateral", "borrowing capacity"],
  index: true,
})

export default function AskAIPage() {
  return <AskPageClient />
}
