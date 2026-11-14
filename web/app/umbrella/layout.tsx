import type { Metadata } from "next"
import type { ReactNode } from "react"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"

export const metadata: Metadata = buildSeoMetadata({
  title: "Umbrella",
  description: "Stake into Umbrella coverage markets and earn boosted rewards.",
  path: "/umbrella",
  keywords: ["umbrella staking", "deficit coverage", "DeFi rewards"],
})

export default function UmbrellaLayout({ children }: { children: ReactNode }) {
  return children
}
