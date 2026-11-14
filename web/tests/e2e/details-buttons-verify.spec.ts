import { expect, test } from "@playwright/test"

test.describe("details buttons — desktop 1280", () => {
  test.use({ viewport: { width: 1280, height: 900 } })

  test("Borrow pool sidebar tabs + Remove/Claim panels", async ({ page }) => {
    await page.goto("/borrow/markets/uni-v3-bluechip-weth-usdc", { waitUntil: "networkidle" })
    const tabs = page.getByRole("tablist", { name: "Pool actions" }).getByRole("tab")
    await expect(tabs).toHaveCount(3)
    await expect(tabs.nth(0)).toHaveText("Pledge")
    await expect(tabs.nth(1)).toHaveText("Remove")
    await expect(tabs.nth(2)).toHaveText("Claim")

    await tabs.nth(1).click()
    await expect(page.getByRole("tab", { name: "Remove" })).toHaveAttribute("aria-selected", "true")
    // Embedded remove action (or launch CTA) for collateral withdrawal
    await expect(
      page.getByText(/Remove|collateral removal|Configure and review your collateral removal/i).first(),
    ).toBeVisible({ timeout: 20_000 })

    await tabs.nth(2).click()
    await expect(page.getByRole("tab", { name: "Claim" })).toHaveAttribute("aria-selected", "true")
    await expect(page.getByText(/Claim|Configure and review your claim/i).first()).toBeVisible({
      timeout: 20_000,
    })
  })

  test("Lend baseline Deposit | Withdraw", async ({ page }) => {
    await page.goto("/lend/markets/usdc", { waitUntil: "networkidle" })
    const tabs = page.getByRole("tablist", { name: "Lend actions" }).getByRole("tab")
    await expect(tabs).toHaveCount(2)
    await expect(tabs.nth(0)).toHaveText("Deposit")
    await expect(tabs.nth(1)).toHaveText("Withdraw")
  })

  test("Multiply sidebar tabs include Close", async ({ page }) => {
    await page.goto("/multiply/markets/aave-gho", { waitUntil: "networkidle" })
    const tabs = page.getByRole("tablist", { name: "Multiply actions" }).getByRole("tab")
    await expect(tabs).toHaveCount(3)
    await expect(tabs.nth(0)).toHaveText("Multiply")
    await expect(tabs.nth(1)).toHaveText("Deleverage")
    await expect(tabs.nth(2)).toHaveText("Close")
    await tabs.nth(2).click()
    await expect(page.getByRole("tab", { name: "Close" })).toHaveAttribute("aria-selected", "true")
    await expect(page.getByText(/Close position|full unwind|Close/i).first()).toBeVisible({
      timeout: 20_000,
    })
  })

  test("Umbrella desktop still Stake Claim Cooldown Unstake", async ({ page }) => {
    await page.goto("/umbrella", { waitUntil: "domcontentloaded" })
    await expect(page.getByRole("tablist", { name: "Umbrella actions" })).toBeVisible({ timeout: 60_000 })
    const tabs = page.getByRole("tablist", { name: "Umbrella actions" }).getByRole("tab")
    await expect(tabs).toHaveCount(4)
    await expect(tabs.nth(0)).toHaveText("Stake")
    await expect(tabs.nth(1)).toHaveText("Claim")
    await expect(tabs.nth(2)).toHaveText("Cooldown")
    await expect(tabs.nth(3)).toHaveText("Unstake")
  })
})

test.describe("details buttons — mobile 390", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true })

  test("Borrow pool mobile bar stays Pledge | Claim (Remove is desktop-only)", async ({ page }) => {
    await page.goto("/borrow/markets/uni-v3-bluechip-weth-usdc", { waitUntil: "networkidle" })
    await expect(page.getByRole("tablist", { name: "Pool actions" })).toHaveCount(0)

    const bar = page.locator(".fixed.inset-x-0.bottom-0")
    await expect(bar.getByRole("link", { name: /Pledge/i })).toHaveAttribute("href", /\/actions\/borrow\/supply/)
    await expect(bar.getByRole("link", { name: /Claim/i })).toHaveAttribute("href", /\/actions\/borrow\/claim/)
    await expect(bar.getByRole("link", { name: /Remove/i })).toHaveCount(0)
  })

  test("Multiply mobile bar stays Multiply | Deleverage (Close is desktop-only)", async ({ page }) => {
    await page.goto("/multiply/markets/aave-gho", { waitUntil: "networkidle" })
    const bar = page.locator(".fixed.inset-x-0.bottom-0")
    await expect(bar.getByRole("link", { name: /Multiply/i })).toBeVisible()
    await expect(bar.getByRole("link", { name: /Deleverage/i })).toBeVisible()
    await expect(bar.getByRole("link", { name: /^Close$/i })).toHaveCount(0)
  })

  test("Umbrella mobile Unstake | Stake, no More", async ({ page }) => {
    await page.goto("/umbrella", { waitUntil: "domcontentloaded" })
    await expect(page.getByRole("button", { name: /Stake in umbrella/i })).toBeVisible({ timeout: 60_000 })
    await expect(page.getByRole("button", { name: /More umbrella/i })).toHaveCount(0)
    await expect(page.getByRole("button", { name: /Unstake from umbrella/i })).toBeVisible()

    await page.getByRole("button", { name: /Unstake from umbrella/i }).click()
    await expect(page.getByRole("tab", { name: "Unstake" })).toHaveAttribute("aria-selected", "true", {
      timeout: 15_000,
    })
  })

  test("Lend mobile baseline Deposit | Withdraw", async ({ page }) => {
    await page.goto("/lend/markets/usdc", { waitUntil: "networkidle" })
    const bar = page.locator(".fixed.inset-x-0.bottom-0")
    await expect(bar.getByRole("link", { name: /Deposit/i })).toBeVisible()
    await expect(bar.getByRole("link", { name: /Withdraw/i })).toBeVisible()
  })

  test("Dashboard My Collaterals cards Claim | Manage", async ({ page }) => {
    await page.goto("/dashboard?tab=borrow", { waitUntil: "networkidle" })
    const heading = page.getByRole("heading", { name: /^My Collaterals$/ })
    await expect(heading).toBeVisible({ timeout: 30_000 })

    // Nearest section ancestor of the heading (SuppliesPanel), not the outer Borrow tab wrapper.
    const section = heading.locator("xpath=ancestor::section[1]")
    const claim = section.getByRole("button", { name: /^Claim$/ }).first()
    const manage = section.getByRole("button", { name: /^Manage$/ }).first()
    await expect(claim).toBeVisible()
    await expect(manage).toBeVisible()
    await expect(section.getByRole("button", { name: /^Borrow$/ })).toHaveCount(0)

    await claim.scrollIntoViewIfNeeded()
    await Promise.all([page.waitForURL(/\/actions\/borrow\/claim/, { timeout: 15_000 }), claim.click()])
  })
})
