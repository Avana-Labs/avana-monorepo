import { unstable_cache } from "next/cache"
import { SITE_STATIC_ROUTES, type SiteRoute } from "@/app/lib/site-static-routes"

export type { SiteRoute }

const ROUTE_MANIFEST_TAG = "site-route-manifest"

/** Synchronous manifest for tests and build-time consumers. */
export { SITE_STATIC_ROUTES }

export const getCachedRouteManifest = unstable_cache(async () => SITE_STATIC_ROUTES, ["site-route-manifest"], {
  revalidate: 3600,
  tags: [ROUTE_MANIFEST_TAG],
})
