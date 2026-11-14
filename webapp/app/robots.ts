import type { MetadataRoute } from "next"
import { SITE_URL } from "@/app/lib/site-url"

export default function robots(): MetadataRoute.Robots {
  const baseUrl = SITE_URL

  return {
    rules: {
      userAgent: "*",
      allow: "/",
      disallow: ["/api/", "/private/"],
    },
    sitemap: `${baseUrl}/sitemap.xml`,
  }
}
