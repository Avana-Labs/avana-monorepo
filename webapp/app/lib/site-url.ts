/**
 * Canonical origin for the DEPLOYED APP.
 *
 * The app is served at app.avana.cc (returns 200 for /, /ask, /borrow, …). The marketing site is a
 * separate host at avana.cc → www.avana.cc, which 308-redirects the app's route paths. So the app must
 * be self-canonical: metadataBase, canonical tags, OpenGraph url, the sitemap, robots.txt, and the
 * Organization/WebSite JSON-LD all point here.
 *
 * This is the APP host only. Links to marketing content (blog, faq, lightpaper, privacy, terms) stay on
 * avana.cc — see app/components/external-links.ts — and are intentionally NOT derived from this.
 */
export const SITE_URL = "https://app.avana.cc"
