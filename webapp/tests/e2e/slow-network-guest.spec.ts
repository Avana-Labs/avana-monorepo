import { expect, test } from "@playwright/test"

test.describe("cold visits on slow connections", () => {
  test.skip(process.env.AVANA_GUEST_CLOSED_GATE_E2E !== "1", "Run with the production guest configuration.")
  test.use({ viewport: { width: 390, height: 844 } })

  test.beforeEach(async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "Network and CPU throttling use CDP.")
    const cdp = await context.newCDPSession(page)
    await cdp.send("Network.enable")
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true })
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 400,
      downloadThroughput: 50_000,
      uploadThroughput: 50_000,
      connectionType: "cellular3g",
    })
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 })
  })

  test("home workspace appears on a cold Slow 3G visit", async ({ page }) => {
    const startedAt = Date.now()
    await page.goto("/", { waitUntil: "domcontentloaded" })
    await expect(page.getByRole("main")).toBeVisible({ timeout: 20_000 })
    await expect(page.getByRole("button", { name: "Select Asset" })).toBeVisible({ timeout: 20_000 })

    const firstContentfulPaintMs = await page.evaluate(
      () => performance.getEntriesByName("first-contentful-paint")[0]?.startTime ?? null,
    )
    expect(firstContentfulPaintMs, "Slow 3G landing page should paint real workspace content").not.toBeNull()
    const interactiveMs = Date.now() - startedAt
    await test.info().attach("cold-slow-3g-landing-metrics.json", {
      body: JSON.stringify({ firstContentfulPaintMs, interactiveMs }, null, 2),
      contentType: "application/json",
    })
    expect(firstContentfulPaintMs).toBeLessThan(8_000)
    expect(interactiveMs, "Slow 3G landing workspace exceeded its cold-visit budget").toBeLessThan(12_000)
  })

  test("first search tap works without waiting for result icons", async ({ page }) => {
    await page.route("**/asset-icons/**", (route) => route.abort())
    await page.goto("/", { waitUntil: "domcontentloaded" })
    // Click as soon as the control is enabled, without a hydration sleep or second tap.
    await page.getByRole("button", { name: "Search Avana", exact: true }).click()
    await expect(page.getByRole("option").first()).toBeVisible({ timeout: 20_000 })
    await page.getByRole("combobox").fill("usdc")
    await expect(page.getByRole("option").first()).toContainText("USDC")
  })

  for (const route of ["/lend", "/dashboard", "/swap"]) {
    test(`${route} renders on a cold connection`, async ({ page }) => {
      const errors: string[] = []
      page.on("pageerror", (error) => errors.push(error.message))
      await page.goto(route, { waitUntil: "domcontentloaded" })
      const content =
        route === "/swap" ? page.getByRole("button", { name: /^Sell asset/ }) : page.getByRole("main").first()
      await expect(content).toBeVisible({ timeout: 20_000 })
      expect(errors).toEqual([])
    })
  }
})
