import { describe, it, expect, vi } from "vitest"

// The SEO modules pull in Next server-only APIs that aren't available in the node test env:
// sitemap() uses unstable_cache, and schema.tsx imports next/headers for the nonce. Stub the
// pieces so the pure metadata/schema builders can be exercised directly.
vi.mock("next/cache", () => ({ unstable_cache: (fn: unknown) => fn, revalidateTag: () => {} }))
vi.mock("next/headers", () => ({ headers: async () => new Map<string, string>() }))

import { SITE_URL } from "@/app/lib/site-url"
import { buildSeoMetadata } from "@/app/lib/seo-metadata"
import robots from "@/app/robots"
import sitemap from "@/app/sitemap"
import { buildOrganizationSchema, buildWebPageSchema, buildWebSiteSchema } from "@/app/components/seo/schema"
import { metadata as askMetadata } from "@/app/ask/page"
import { metadata as homeMetadata } from "@/app/page"
import { metadata as borrowMetadata } from "@/app/borrow/page"
import { metadata as lendMetadata } from "@/app/lend/page"
import { metadata as multiplyMetadata } from "@/app/multiply/page"

// The marketing host 308-redirects the app's route paths, so no app-served discoverability
// signal may point at it.
const MARKETING_HOST = "https://avana.cc"

describe("SEO canonical host", () => {
  it("SITE_URL is the app host, not the marketing host", () => {
    expect(SITE_URL).toBe("https://app.avana.cc")
  })

  it("buildSeoMetadata builds a per-path canonical + OG url on the app host", () => {
    const md = buildSeoMetadata({ title: "Borrow", description: "d", path: "/borrow" })
    expect(md.alternates?.canonical).toBe("/borrow")
    expect(md.openGraph?.url).toBe(`${SITE_URL}/borrow`)
    expect(JSON.stringify(md)).not.toContain(MARKETING_HOST)
  })

  it("robots points crawlers at the app-host sitemap", () => {
    const r = robots()
    expect(r.sitemap).toBe(`${SITE_URL}/sitemap.xml`)
    expect(JSON.stringify(r)).not.toContain(MARKETING_HOST)
  })

  it("every sitemap URL is on the app host", async () => {
    const entries = await sitemap()
    expect(entries.length).toBeGreaterThan(0)
    for (const entry of entries) {
      expect(entry.url.startsWith(SITE_URL)).toBe(true)
    }
  })

  it("JSON-LD uses the app host, drops the dead SearchAction, and encodes the logo URL", () => {
    const site = buildWebSiteSchema() as Record<string, unknown>
    const org = buildOrganizationSchema() as Record<string, unknown>
    const page = buildWebPageSchema({ name: "Borrow", description: "d", url: `${SITE_URL}/borrow` }) as {
      isPartOf: { url: string }
    }
    expect(site.url).toBe(SITE_URL)
    // Removed: potentialAction targeted /search, which 404s.
    expect(site.potentialAction).toBeUndefined()
    expect(org.url).toBe(SITE_URL)
    expect(org.logo).toBe(`${SITE_URL}/Avana%20Favicon.png`)
    expect(String(org.logo)).not.toContain(" ")
    expect(page.isPartOf.url).toBe(SITE_URL)
  })
})

describe("Ask AI metadata", () => {
  it("self-canonicalizes to /ask instead of inheriting the homepage canonical", () => {
    expect(askMetadata.alternates?.canonical).toBe("/ask")
    expect(askMetadata.openGraph?.url).toBe(`${SITE_URL}/ask`)
    expect(JSON.stringify(askMetadata)).not.toContain(MARKETING_HOST)
  })
})

describe("Homepage metadata", () => {
  it("uses a descriptive title, avoiding the 'Avana | Avana' template duplication", () => {
    // Root template is "%s | Avana"; a title of "Avana" renders "Avana | Avana".
    expect(homeMetadata.title).not.toBe("Avana")
    expect(typeof homeMetadata.title).toBe("string")
    expect(homeMetadata.alternates?.canonical).toBe("/")
  })
})

describe("noindex strategy (marketing owns SEO)", () => {
  it("defaults routes to noindex and opts specific ones back in via index: true", () => {
    // A gated route sets no robots override, so it inherits the layout's noindex default.
    expect(buildSeoMetadata({ title: "t", description: "d", path: "/borrow" }).robots).toBeUndefined()
    expect(buildSeoMetadata({ title: "t", description: "d", path: "/", index: true }).robots).toEqual({
      index: true,
      follow: true,
    })
  })

  it("keeps / and /ask indexable", () => {
    expect((homeMetadata.robots as { index?: boolean } | undefined)?.index).toBe(true)
    expect((askMetadata.robots as { index?: boolean } | undefined)?.index).toBe(true)
  })

  it("keeps the guest-open product pages indexable", () => {
    for (const metadata of [borrowMetadata, lendMetadata, multiplyMetadata]) {
      expect((metadata.robots as { index?: boolean } | undefined)?.index).toBe(true)
    }
  })

  it("sitemap lists the open routes, not the onboarding-gated ones", async () => {
    const urls = (await sitemap()).map((entry) => entry.url)
    expect(urls).toContain(SITE_URL)
    expect(urls).toContain(`${SITE_URL}/ask`)
    for (const route of ["/borrow", "/lend", "/multiply"]) expect(urls).toContain(`${SITE_URL}${route}`)
    expect(urls.some((url) => url.includes("/dashboard"))).toBe(false)
    expect(urls.some((url) => url.includes("/umbrella"))).toBe(false)
  })
})
