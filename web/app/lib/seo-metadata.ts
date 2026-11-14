import type { Metadata } from "next"
import { SITE_URL } from "./site-url"

type SeoMetadataInput = {
  title: string
  description: string
  path: string
  keywords?: string[]
  // Opt a route back into indexing. The root layout defaults every app route to noindex; routes
  // that render public content for guests (/, /ask, Borrow, Lend and their detail pages)
  // pass index: true. The onboarding-gated dashboard and umbrella stay noindex.
  index?: boolean
}

export function buildSeoMetadata({ title, description, path, keywords, index }: SeoMetadataInput): Metadata {
  const url = `${SITE_URL}${path}`

  return {
    title,
    description,
    keywords,
    ...(index ? { robots: { index: true, follow: true } } : {}),
    alternates: {
      canonical: path,
    },
    openGraph: {
      type: "website",
      url,
      title,
      description,
      siteName: "Avana",
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
    },
  }
}
