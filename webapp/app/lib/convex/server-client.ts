import "server-only"
import { ConvexHttpClient } from "convex/browser"
import { fetchWithReadDeadline } from "@/app/lib/detail-page/public-metadata-cache"
import { requestCache } from "@/app/lib/detail-page/request-cache"
import { reportServerFetchFailure } from "@/app/lib/detail-page/report-server-fetch-failure"

// Public metadata only. Reuse the client within an RSC request without importing
// the borrow catalog and every detail-page hydration helper into the root layout.
export const publicConvexClient = requestCache((): ConvexHttpClient | null => {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) return null
  try {
    return new ConvexHttpClient(url, { fetch: fetchWithReadDeadline })
  } catch (error) {
    reportServerFetchFailure("convexClient", error)
    return null
  }
})
