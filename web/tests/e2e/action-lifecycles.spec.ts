import { expect, test } from "@playwright/test"
import { installSiweSession, walletFromAuthToken } from "./helpers/siwe-auth"

const AUTH_TOKEN = process.env.AVANA_E2E_AUTH_TOKEN
const RUN_STAGING_E2E =
  process.env.RUN_ACTION_CONVEX_E2E === "1" && process.env.AVANA_E2E_STAGING === "1" && Boolean(AUTH_TOKEN)

const lifecycles = [
  {
    name: "borrow open",
    path: process.env.AVANA_E2E_BORROW_PATH,
    dashboardTab: "Borrow",
    dashboardHref: "/dashboard?tab=borrow",
  },
  {
    name: "multiply open",
    path: process.env.AVANA_E2E_MULTIPLY_PATH,
    dashboardTab: "Multiply",
    dashboardHref: "/dashboard?tab=multiply",
  },
  {
    name: "borrow repay",
    path: process.env.AVANA_E2E_REPAY_PATH,
    dashboardTab: "Borrow",
    dashboardHref: "/dashboard?tab=borrow",
  },
  // Lend deposit/withdraw no longer reconcile on the dashboard — the lend account
  // section moved to the rewards page (LendAccountSection returns to /rewards).
] as const

test.describe.configure({ mode: "serial" })
test.skip(
  !RUN_STAGING_E2E,
  "Action mutation E2E requires an isolated staging Convex deployment, an auth token, and explicit opt-in.",
)

for (const lifecycle of lifecycles) {
  test(`${lifecycle.name} completes configure, review, success, and dashboard reconciliation`, async ({ page }) => {
    test.skip(!lifecycle.path, `Set the staging fixture route for ${lifecycle.name}.`)
    test.skip(
      !process.env.AVANA_E2E_SESSION_SECRET,
      "Set AVANA_E2E_SESSION_SECRET so Playwright can mint an HttpOnly avana_siwe session on staging.",
    )
    test.setTimeout(60_000)
    const wallet = walletFromAuthToken(AUTH_TOKEN!)
    await installSiweSession(page, AUTH_TOKEN!)
    expect(wallet).toMatch(/^0x[0-9a-f]{40}$/)
    await page.goto(lifecycle.path!, { waitUntil: "commit" })

    const configurePrimary = page.getByTestId("action-footer").locator("button").last()
    await expect(configurePrimary).toBeEnabled({ timeout: 15_000 })
    await configurePrimary.click()

    const review = page.getByTestId("action-review-stage")
    await expect(review).toBeVisible()
    await expect(review.getByText("Quote", { exact: true })).toBeVisible()
    await review.getByTestId("action-footer").locator("button").last().click()

    const success = page.getByTestId("action-success-stage")
    await expect(success).toBeVisible({ timeout: 30_000 })
    await expect(success.getByText("Quote", { exact: true })).toBeVisible()

    await success.getByTestId("action-footer").locator(`a[href="${lifecycle.dashboardHref}"]`).click()
    await expect(page).toHaveURL(new RegExp(`${lifecycle.dashboardHref.replace("?", "\\?")}$`))
    await expect(page.getByRole("tab", { name: lifecycle.dashboardTab, selected: true })).toBeVisible({
      timeout: 15_000,
    })
  })
}
