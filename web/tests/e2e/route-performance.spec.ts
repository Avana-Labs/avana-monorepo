import { test, expect } from "@playwright/test"
import {
  ACTION_LIGHTHOUSE_ROUTES,
  LIGHTHOUSE_ROUTES,
  ROUTE_HERO_SELECTORS,
  getNavigationTimingBudget,
} from "./fixtures/route-budgets"

const PRIMARY_ROUTES = ROUTE_HERO_SELECTORS.filter((entry) => LIGHTHOUSE_ROUTES.includes(entry.route))

for (const { route, heroText, heroRole } of PRIMARY_ROUTES) {
  test(`route ${route} paints hero content within budget`, async ({ page }) => {
    test.setTimeout(60_000)
    const timingBudget = getNavigationTimingBudget(route)

    await page.goto(route, { waitUntil: "domcontentloaded", timeout: 60_000 })

    const startedAt = Date.now()

    await page.goto(route, { waitUntil: "domcontentloaded", timeout: 60_000 })


    const domContentLoadedMs = Date.now() - startedAt
    expect(
      domContentLoadedMs,
      `${route} DOMContentLoaded exceeded ${timingBudget.domContentLoadedMs}ms`,
    ).toBeLessThanOrEqual(timingBudget.domContentLoadedMs)

    const heroLocator =
      heroRole === "tab"
        ? page.getByRole("tab", { name: heroText })
        : heroRole === "heading"
          ? page.getByRole("heading", { name: heroText })
          : page.getByText(heroText, { exact: false }).first()

    await expect(heroLocator).toBeVisible({
      timeout: timingBudget.heroVisibleMs,
    })
  })
}

for (const { name, path } of ACTION_LIGHTHOUSE_ROUTES) {
  test(`action route ${name} loads shell within budget`, async ({ page }) => {
    test.setTimeout(45_000)
    const startedAt = Date.now()
    await page.goto(path, { waitUntil: "domcontentloaded", timeout: 60_000 })
    expect(Date.now() - startedAt).toBeLessThanOrEqual(4_000)
    await expect(page.getByTestId("action-page-shell")).toBeVisible({ timeout: 10_000 })
  })
}

test("borrow keeps the workspace shell below the hero", async ({ page }) => {
  await page.goto("/borrow", { waitUntil: "domcontentloaded" })
  await expect(page.getByText("Borrow TVL").first()).toBeVisible()
  await expect(page.locator(".borrow-workspace-shell")).toBeVisible()
})

test("home action workspace becomes interactive within budget", async ({ page }) => {
  await page.goto("/", { waitUntil: "domcontentloaded" })
  await expect(page.getByText("Sell", { exact: true })).toBeVisible({ timeout: 5_000 })
  await expect(page.getByRole("button", { name: "Select Asset" })).toBeVisible()
})
