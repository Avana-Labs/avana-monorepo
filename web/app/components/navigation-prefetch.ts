"use client"

import { useSpeculativeLoading } from "@/app/lib/performance/speculative-loading"

const HEAVY_PRODUCT_ROUTES = new Set(["/borrow", "/lend"])

/**
 * Avoid eager RSC/Convex hydration for product catalogs. In the App Router `prefetch={false}`
 * also disables hover prefetch, so these routes load on click.
 */
export function shouldPrefetchNavigation(href: string, isSignedIn: boolean) {
  return isSignedIn && !HEAVY_PRODUCT_ROUTES.has(href)
}

export function useNavigationPrefetch(isSignedIn: boolean) {
  const allowed = useSpeculativeLoading()
  return (href: string) => allowed && shouldPrefetchNavigation(href, isSignedIn)
}
