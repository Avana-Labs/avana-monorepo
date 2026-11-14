import { expect, test } from "@playwright/test"

const routes = [
  "/borrow/markets/uni-v2-wbtc-usdc",
  "/borrow/markets/uni-v3-bluechip-weth-usdc",
  "/borrow/assets/usdc",
  "/borrow/assets/wbtc",
]

test("every Borrow detail route family compiles and renders without a route error", async ({ page }) => {
  test.setTimeout(180_000)
  const pageErrors: string[] = []
  page.on("pageerror", (error) => pageErrors.push(error.message))

  for (const route of routes) {
    const response = await page.goto(route, { waitUntil: "commit", timeout: 60_000 })
    expect(response?.status(), `${route} returned an unsuccessful response`).toBeLessThan(400)
    await expect(page.locator("main")).toBeVisible({ timeout: 15_000 })
    await expect(page.getByText("Something went wrong", { exact: true })).toHaveCount(0)
  }

  expect(pageErrors, `Borrow detail routes emitted runtime errors:\n${pageErrors.join("\n")}`).toEqual([])
})
