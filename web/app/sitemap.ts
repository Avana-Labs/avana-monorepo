import type { MetadataRoute } from "next"
import { getCachedRouteManifest } from "@/app/lib/route-manifest"
import { SITE_URL } from "@/app/lib/site-url"

const baseUrl = SITE_URL

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const routes = await getCachedRouteManifest()
  const lastModified = new Date()

  // Only indexable routes belong in the sitemap; the rest are noindex (wallet-gated).
  const entries = routes
    .filter((route) => route.indexable)
    .map(({ route, priority }) => ({
      url: `${baseUrl}${route}`,
      lastModified,
      changeFrequency: "daily" as const,
      priority,
    }))

  // /ask is the one crawlable product route with real public content, but it isn't part of the
  // perf-budget manifest, so it's added here.
  entries.push({ url: `${baseUrl}/ask`, lastModified, changeFrequency: "daily", priority: 0.9 })

  return entries
}
