export type SiteRoute = {
  route: string
  priority: number
  // Whether the route belongs in the sitemap: the guest-open product routes. Onboarding-gated and
  // utility routes are noindex, so they stay in this manifest for perf budgets but are excluded from
  // the sitemap. Kept in sync with the layout noindex default + buildSeoMetadata({ index: true }).
  indexable?: boolean
}

/** Shared static route manifest for build, tests, and performance budgets. */
export const SITE_STATIC_ROUTES: SiteRoute[] = [
  { route: "", priority: 1.0, indexable: true },
  { route: "/borrow", priority: 0.9, indexable: true },
  { route: "/lend", priority: 0.85, indexable: true },
  { route: "/swap", priority: 0.82 },
  { route: "/dashboard", priority: 0.72 },
  { route: "/support-center", priority: 0.45 },
]
