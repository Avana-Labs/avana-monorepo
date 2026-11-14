import { expect, test } from "@playwright/test"
import { ACTION_LIGHTHOUSE_ROUTES } from "./fixtures/route-budgets"

test.describe("action pages smoke", () => {
  for (const route of ACTION_LIGHTHOUSE_ROUTES) {
    test(`${route.name} loads shell`, async ({ page }) => {
      await page.goto(route.path, { waitUntil: "domcontentloaded", timeout: 60_000 })
      await expect(page.getByTestId("action-page-shell")).toBeVisible({ timeout: 30_000 })
    })
  }
})
