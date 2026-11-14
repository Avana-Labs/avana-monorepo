import { SITE_STATIC_ROUTES } from "@/app/lib/site-static-routes"

export {
  ACTION_LIGHTHOUSE_ROUTES,
  LIGHTHOUSE_ROUTES,
  NAVIGATION_TIMING_BUDGETS,
  ROUTE_HERO_SELECTORS,
  ROUTE_TIMING_OVERRIDES,
  getNavigationTimingBudget,
  type ActionLighthouseRoute,
  type LighthouseRoute,
  type NavigationTimingBudget,
  type RouteHeroSelector,
} from "@/app/lib/performance/route-budgets.data"

import { ACTION_LIGHTHOUSE_ROUTES, LIGHTHOUSE_ROUTES } from "@/app/lib/performance/route-budgets.data"

export const ALL_LIGHTHOUSE_ROUTE_PATHS = [
  ...LIGHTHOUSE_ROUTES,
  ...ACTION_LIGHTHOUSE_ROUTES.map((route) => route.path),
] as const

export const LIGHTHOUSE_CATEGORY_BUDGETS = {
  performance: 100,
  accessibility: 100,
  "best-practices": 100,
  seo: 100,
} as const

export type LighthouseCategory = keyof typeof LIGHTHOUSE_CATEGORY_BUDGETS

export function scoreLighthouseCategory(score: number | null | undefined) {
  return Math.round((score ?? 0) * 100)
}

export function isLighthouseScoreWithinBudget(category: LighthouseCategory, score: number) {
  return score >= LIGHTHOUSE_CATEGORY_BUDGETS[category]
}

export function getAuditedStaticRoutes() {
  return SITE_STATIC_ROUTES.map((entry) => (entry.route === "" ? "/" : entry.route))
}
