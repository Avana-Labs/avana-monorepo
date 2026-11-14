import { expect, test } from "@playwright/test"

// The dashboard/portfolio routes go through Next.js's dev-mode cold compilation
// on CI's fresh worker (no build cache), which is materially slower than local
// (35s+ isn't uncommon). Match the borrow-detail-routes.spec.ts budget so a
// legitimate render isn't racing a 15s clock — the assertions themselves still
// fail closed if the page renders wrong, just with more headroom for compile.
test.setTimeout(180_000)

test("dashboard page renders its product account tabs", async ({ page }) => {
  await page.goto("/dashboard", { waitUntil: "commit", timeout: 60_000 })

  const borrowTab = page.getByRole("tab", { name: "Borrow" }).first()
  await expect(borrowTab).toBeVisible({ timeout: 60_000 })
  await borrowTab.click()
  await expect(page.getByRole("heading", { name: "Borrow Balance" })).toBeVisible({ timeout: 30_000 })
})

test("old portfolio and rewards routes redirect to the dashboard page", async ({ page }) => {
  await page.goto("/portfolio", { waitUntil: "commit", timeout: 60_000 })
  await expect(page).toHaveURL(/\/dashboard$/, { timeout: 30_000 })

  await page.goto("/rewards", { waitUntil: "commit", timeout: 60_000 })
  await expect(page).toHaveURL(/\/dashboard$/, { timeout: 30_000 })
})
