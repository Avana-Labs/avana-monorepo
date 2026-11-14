import routeConfig from "../../../config/performance-routes.json"

/** Playwright-safe route budget data for e2e (kept outside app/ imports). */
export const LIGHTHOUSE_ROUTES = routeConfig.primaryRoutes.map(({ route }) => route)

export type LighthouseRoute = (typeof LIGHTHOUSE_ROUTES)[number]

export type ActionLighthouseRoute = {
  name: string
  path: string
}

export const ACTION_LIGHTHOUSE_ROUTES: ActionLighthouseRoute[] = routeConfig.actionRoutes.map(({ name, path }) => ({
  name,
  path,
}))

export type NavigationTimingBudget = {
  domContentLoadedMs: number
  heroVisibleMs: number
}

export const NAVIGATION_TIMING_BUDGETS: NavigationTimingBudget = {
  domContentLoadedMs: 4_000,
  heroVisibleMs: 5_000,
}

export const ROUTE_TIMING_OVERRIDES: Partial<Record<LighthouseRoute, Partial<NavigationTimingBudget>>> = {
  "/lend/markets/usdc": {
    domContentLoadedMs: 7_000,
  },
}

export function getNavigationTimingBudget(route: LighthouseRoute): NavigationTimingBudget {
  const override = ROUTE_TIMING_OVERRIDES[route] ?? {}
  return {
    domContentLoadedMs: override.domContentLoadedMs ?? NAVIGATION_TIMING_BUDGETS.domContentLoadedMs,
    heroVisibleMs: override.heroVisibleMs ?? NAVIGATION_TIMING_BUDGETS.heroVisibleMs,
  }
}

export type RouteHeroSelector = {
  route: LighthouseRoute
  heroText: string
  heroRole?: "tab" | "heading"
}

export const ROUTE_HERO_SELECTORS: RouteHeroSelector[] = routeConfig.primaryRoutes.map(
  ({ route, heroText, heroRole }) => ({
    route,
    heroText,
    heroRole: heroRole as RouteHeroSelector["heroRole"],
  }),
)
