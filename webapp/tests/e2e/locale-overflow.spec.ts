import { expect, test } from "@playwright/test"

/**
 * CTA / layout overflow guard (audit LOW-7). Long translations (German, Russian, Spanish,
 * Indonesian run 1.5–2.3× the English) must not push the page into horizontal scroll on a
 * 375px mobile viewport. Locale is client-side (localStorage "avana-language"), so this runs
 * in the Convex-less Playwright test mode. Asserts no PAGE-LEVEL horizontal overflow — the
 * clearest, least-flaky signal that a translated label broke the layout.
 */

const LOCALES = ["DE", "RU", "ES", "ID"] as const
const PATHS = ["/", "/borrow"] as const

for (const lang of LOCALES) {
  for (const path of PATHS) {
    test(`no horizontal overflow at 375px — ${lang} ${path}`, async ({ page }) => {
      await page.addInitScript((l) => window.localStorage.setItem("avana-language", l), lang)
      await page.setViewportSize({ width: 375, height: 812 })
      await page.goto(path, { waitUntil: "networkidle" })
      // Let the async locale chunk load and re-render the labels before measuring.
      await page.waitForTimeout(600)

      const { scrollWidth, clientWidth } = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      }))

      // Allow 1px for sub-pixel rounding; anything more is a real overflow.
      expect(
        scrollWidth,
        `${lang} ${path} scrolls horizontally (scrollWidth ${scrollWidth} > ${clientWidth})`,
      ).toBeLessThanOrEqual(clientWidth + 1)
    })
  }
}
