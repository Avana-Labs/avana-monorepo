import { test, expect, type Page, type ConsoleMessage } from "@playwright/test"

type AuditIssue = {
  viewport: string
  route: string
  category: "console" | "visibility" | "navigation" | "interaction" | "a11y"
  message: string
}

const auditIssues: AuditIssue[] = []

function isBenignConsoleError(text: string) {
  return (
    text.includes("Download the React DevTools") ||
    text.includes("Hydration") ||
    text.includes("favicon") ||
    text.includes("ResizeObserver") ||
    text.includes("webpack-hmr") ||
    text.includes("WebSocket connection")
  )
}

function trackConsole(page: Page, viewport: string, route: string) {
  page.on("console", (msg: ConsoleMessage) => {
    if (msg.type() === "error") {
      const text = msg.text()
      if (isBenignConsoleError(text)) {
        return
      }
      auditIssues.push({
        viewport,
        route,
        category: "console",
        message: text.slice(0, 500),
      })
    }
  })

  page.on("pageerror", (error) => {
    auditIssues.push({
      viewport,
      route,
      category: "console",
      message: `Page error: ${error.message}`.slice(0, 500),
    })
  })
}

async function checkLowContrastText(page: Page, viewport: string, route: string) {
  const tinyText = await page.evaluate(() => {
    const issues: string[] = []
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT)
    let node = walker.currentNode as Element | null
    while (node) {
      const el = node as HTMLElement
      const style = window.getComputedStyle(el)
      const fontSize = parseFloat(style.fontSize)
      const text = el.textContent?.trim() ?? ""
      if (fontSize > 0 && fontSize < 10) {
        issues.push(`Text "${text.slice(0, 40)}" at ${fontSize}px`)
      }
      node = walker.nextNode() as Element | null
    }
    return issues.slice(0, 5)
  })

  for (const issue of tinyText) {
    auditIssues.push({ viewport, route, category: "visibility", message: issue })
  }
}

async function clickAllTabs(page: Page, viewport: string, route: string) {
  const tabs = page.locator('[role="tab"]:visible')
  const count = await tabs.count()
  for (let i = 0; i < count; i++) {
    const tab = tabs.nth(i)
    const label = (await tab.textContent())?.trim() ?? `tab-${i}`
    try {
      await tab.click({ timeout: 5000 })
      await page.waitForTimeout(300)
      const selected = await tab.getAttribute("aria-selected")
      if (selected !== "true") {
        auditIssues.push({
          viewport,
          route,
          category: "interaction",
          message: `Tab "${label}" did not become selected after click`,
        })
      }
    } catch (e) {
      auditIssues.push({
        viewport,
        route,
        category: "interaction",
        message: `Failed to click tab "${label}": ${(e as Error).message}`,
      })
    }
  }
}

async function browseRoute(page: Page, viewport: string, route: string, options?: { clickTabs?: boolean }) {
  trackConsole(page, viewport, route)

  const response = await page.goto(route, { waitUntil: "networkidle", timeout: 60_000 })
  if (!response || response.status() >= 400) {
    auditIssues.push({
      viewport,
      route,
      category: "navigation",
      message: `HTTP ${response?.status() ?? "no response"}`,
    })
    return
  }

  // Wait for main content
  await page.waitForSelector("main, [role='main'], body", { timeout: 15_000 }).catch(() => {
    auditIssues.push({ viewport, route, category: "navigation", message: "No main content found" })
  })

  await page.waitForTimeout(500)

  if (options?.clickTabs) {
    await clickAllTabs(page, viewport, route)
  }

  await checkLowContrastText(page, viewport, route)

  // Check charts render (canvas or svg)
  const charts = page.locator("canvas, .recharts-wrapper, [data-chart]")
  const chartCount = await charts.count()
  if (chartCount > 0) {
    for (let i = 0; i < Math.min(chartCount, 3); i++) {
      const chart = charts.nth(i)
      const box = await chart.boundingBox()
      if (!box || box.width < 10 || box.height < 10) {
        auditIssues.push({
          viewport,
          route,
          category: "visibility",
          message: `Chart ${i} has zero or tiny dimensions (${box?.width}x${box?.height})`,
        })
      }
    }
  }
}

async function toggleTheme(page: Page, viewport: string, route: string) {
  const themeToggle = page
    .locator(
      '[aria-label*="theme" i], [aria-label*="dark" i], [aria-label*="light" i], button:has-text("Dark"), button:has-text("Light")',
    )
    .first()
  if (await themeToggle.isVisible().catch(() => false)) {
    await themeToggle.click()
    await page.waitForTimeout(400)
    await checkLowContrastText(page, viewport, `${route} (dark)`)
  }
}

async function openMobileMenu(page: Page, viewport: string) {
  const menuButton = page.locator('[aria-label*="menu" i], [aria-label*="navigation" i], button:has(svg)').first()
  if (await menuButton.isVisible().catch(() => false)) {
    await menuButton.click()
    await page.waitForTimeout(300)
    const navLinks = page.locator("nav a, [role='dialog'] a")
    const linkCount = await navLinks.count()
    if (linkCount === 0) {
      auditIssues.push({
        viewport,
        route: "/",
        category: "interaction",
        message: "Mobile menu opened but no nav links found",
      })
    }
  }
}

// ─── Home Page ───────────────────────────────────────────────────────────────

test.describe("Home page", () => {
  test("browse home fully", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/")

    // Click home mode tabs: Borrow, Repay, Claim, Remove
    const modeTabs = page.locator('[role="tablist"] [role="tab"]')
    const modeCount = await modeTabs.count()
    for (let i = 0; i < modeCount; i++) {
      await modeTabs.nth(i).click()
      await page.waitForTimeout(400)
    }

    await toggleTheme(page, viewport, "/")

    if (viewport === "mobile") {
      await openMobileMenu(page, viewport)
    }
  })
})

// ─── Borrow ──────────────────────────────────────────────────────────────────

test.describe("Borrow pages", () => {
  test("browse borrow main and tabs", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/borrow", { clickTabs: false })

    // Open each filter pill (All Chains / Hubs / Markets / Assets), pick the first live option,
    // then clear everything again.
    const filters = page.getByTestId("market-filters")
    for (const facet of ["chains", "hubs", "markets", "assets"]) {
      await filters.locator(`[data-facet='${facet}'] > button`).first().click()
      const panel = page.getByRole("dialog")
      await expect(panel).toBeVisible()
      await panel.getByRole("checkbox").and(page.locator(":not([disabled])")).first().click()
      await page.keyboard.press("Escape")
      await expect(panel).toBeHidden()
    }
    const clearAll = filters.getByRole("button", { name: "Clear all" })
    if (await clearAll.isVisible().catch(() => false)) await clearAll.click()

    // Click first pool link if available
    const poolLink = page.locator("a[href*='/borrow/']").first()
    if (await poolLink.isVisible().catch(() => false)) {
      const href = await poolLink.getAttribute("href")
      await poolLink.click()
      await page.waitForLoadState("networkidle")
      await browseRoute(page, viewport, href ?? "/borrow")
    }

    await toggleTheme(page, viewport, "/borrow")
  })

  test("browse borrow workspace tabs", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await page.goto("/borrow", { waitUntil: "networkidle" })
    trackConsole(page, viewport, "/borrow workspace")

    const workspaceTabs = page.locator('[role="tab"]:visible')
    const count = await workspaceTabs.count()
    for (let i = 0; i < count; i++) {
      await workspaceTabs.nth(i).click()
      await page.waitForTimeout(400)
    }
  })
})

// ─── Lend ────────────────────────────────────────────────────────────────────

test.describe("Lend pages", () => {
  test("browse lend main", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/lend", { clickTabs: true })

    const marketLink = page.locator("a[href*='/lend/markets/']").first()
    if (await marketLink.isVisible().catch(() => false)) {
      const href = await marketLink.getAttribute("href")
      const featuredCarousel = page.locator("[data-featured-carousel]").first()
      if (await featuredCarousel.isVisible().catch(() => false)) {
        await featuredCarousel.hover()
      }
      await marketLink.click({ force: true })
      await page.waitForLoadState("networkidle")
      await browseRoute(page, viewport, href ?? "/lend")
    }

    await toggleTheme(page, viewport, "/lend")
  })
})

// ─── Dashboard ───────────────────────────────────────────────────────────────

test.describe("Dashboard", () => {
  test("browse all dashboard tabs", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/dashboard", { clickTabs: true })
    await toggleTheme(page, viewport, "/dashboard")
  })
})

// ─── Rewards ─────────────────────────────────────────────────────────────────

test.describe("Rewards", () => {
  test("browse rewards tabs and quests", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/rewards", { clickTabs: true })

    // Click promo tabs within rewards
    const promoTabs = page.locator("#rewards-tabs button[role='tab']")
    const count = await promoTabs.count()
    for (let i = 0; i < count; i++) {
      await promoTabs
        .nth(i)
        .click()
        .catch(() => {})
      await page.waitForTimeout(300)
    }

    await toggleTheme(page, viewport, "/rewards")
  })
})

// ─── Support Center ──────────────────────────────────────────────────────────

test.describe("Support Center", () => {
  test("browse support center", async ({ page }, testInfo) => {
    const viewport = testInfo.project.name
    await browseRoute(page, viewport, "/support-center")
    await toggleTheme(page, viewport, "/support-center")
  })
})

// ─── Report ──────────────────────────────────────────────────────────────────

test.afterAll(async () => {
  if (auditIssues.length > 0) {
    // eslint-disable-next-line no-console -- audit report output
    console.log("\n=== AUDIT ISSUES FOUND ===")
    const grouped = new Map<string, AuditIssue[]>()
    for (const issue of auditIssues) {
      const key = `${issue.category}: ${issue.message}`
      if (!grouped.has(key)) grouped.set(key, [])
      grouped.get(key)!.push(issue)
    }
    for (const [, issues] of grouped) {
      const locations = issues.map((i) => `${i.viewport}@${i.route}`).join(", ")
      // eslint-disable-next-line no-console -- audit report output
      console.log(`[${issues[0].category}] ${issues[0].message}`)
      // eslint-disable-next-line no-console -- audit report output
      console.log(`  Locations: ${locations}`)
    }
    // eslint-disable-next-line no-console -- audit report output
    console.log(`\nTotal unique issues: ${grouped.size}`)
    // eslint-disable-next-line no-console -- audit report output
    console.log(`Total issue instances: ${auditIssues.length}`)
  } else {
    // eslint-disable-next-line no-console -- audit report output
    console.log("\n=== NO AUDIT ISSUES FOUND ===")
  }
})

// Fail test if critical console errors found (for CI)
test("no critical console errors across audit", async () => {
  const critical = auditIssues.filter((i) => i.category === "console" && !isBenignConsoleError(i.message))
  expect(
    critical,
    `Found ${critical.length} console errors:\n${critical.map((i) => i.message).join("\n")}`,
  ).toHaveLength(0)
})
