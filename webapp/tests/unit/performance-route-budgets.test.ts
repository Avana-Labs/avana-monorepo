import { describe, expect, it } from "vitest"
import {
  ACTION_LIGHTHOUSE_ROUTES,
  ALL_LIGHTHOUSE_ROUTE_PATHS,
  LIGHTHOUSE_CATEGORY_BUDGETS,
  LIGHTHOUSE_ROUTES,
  NAVIGATION_TIMING_BUDGETS,
  ROUTE_HERO_SELECTORS,
  isLighthouseScoreWithinBudget,
  scoreLighthouseCategory,
} from "@/app/lib/performance/route-budgets"
import { SITE_STATIC_ROUTES } from "@/app/lib/site-static-routes"

describe("performance route budgets", () => {
  it("audits every high-priority static route from the manifest", () => {
    const manifestRoutes = SITE_STATIC_ROUTES.map((entry) => (entry.route === "" ? "/" : entry.route))

    for (const route of manifestRoutes) {
      expect(LIGHTHOUSE_ROUTES).toContain(route)
    }
  })

  it("includes detail and action routes in the lighthouse manifest", () => {
    expect(LIGHTHOUSE_ROUTES.some((route) => route.includes("/markets/"))).toBe(true)
    expect(LIGHTHOUSE_ROUTES.some((route) => route.includes("/assets/"))).toBe(true)
    expect(ACTION_LIGHTHOUSE_ROUTES.length).toBeGreaterThanOrEqual(10)
    expect(ALL_LIGHTHOUSE_ROUTE_PATHS.length).toBeGreaterThan(LIGHTHOUSE_ROUTES.length)
  })

  it("maps each primary route to an early-visible hero marker", () => {
    const primaryRoutes = ["/", "/borrow", "/lend", "/dashboard", "/support-center"]

    for (const route of primaryRoutes) {
      expect(ROUTE_HERO_SELECTORS.some((entry) => entry.route === route)).toBe(true)
    }
  })

  it("normalizes lighthouse category scores", () => {
    expect(scoreLighthouseCategory(0.819)).toBe(82)
    expect(scoreLighthouseCategory(null)).toBe(0)
  })

  it("targets perfect lighthouse category floors", () => {
    expect(LIGHTHOUSE_CATEGORY_BUDGETS.performance).toBe(100)
    expect(isLighthouseScoreWithinBudget("performance", 100)).toBe(true)
    expect(isLighthouseScoreWithinBudget("accessibility", 100)).toBe(true)
  })

  it("keeps navigation timing budgets realistic for CI", () => {
    expect(NAVIGATION_TIMING_BUDGETS.domContentLoadedMs).toBeGreaterThanOrEqual(2_000)
    expect(NAVIGATION_TIMING_BUDGETS.heroVisibleMs).toBeGreaterThan(NAVIGATION_TIMING_BUDGETS.domContentLoadedMs)
  })
})
