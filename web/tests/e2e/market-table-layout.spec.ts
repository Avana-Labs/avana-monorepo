import { expect, test, type Page } from "@playwright/test"

/**
 * Market tables share one column layout (`tableColumnLayout`). At desktop widths they must fit
 * their container — no horizontal scroll — and every table on a page must put the pinned
 * asset column's edge in the same place. Below the layout's min width the data columns
 * scroll under the pinned column instead of the whole row sliding away.
 */

const PATHS = ["/borrow", "/lend", "/multiply"] as const

async function visibleTables(page: Page) {
  await page.locator("table tbody tr").first().waitFor({ state: "visible" })
  return page.evaluate(() =>
    [...document.querySelectorAll("table")]
      .filter((table) => (table as HTMLElement).offsetParent !== null)
      .map((table) => {
        const scroller = table.parentElement as HTMLElement
        const pinned = table.querySelector<HTMLElement>("thead th.sticky")
        return {
          scrollWidth: scroller.scrollWidth,
          clientWidth: scroller.clientWidth,
          pinnedRight: pinned
            ? Math.round(pinned.getBoundingClientRect().right - scroller.getBoundingClientRect().left)
            : null,
        }
      }),
  )
}

for (const width of [1280, 1440]) {
  for (const path of PATHS) {
    test(`${path} tables fit without horizontal scroll at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      await page.goto(path, { waitUntil: "networkidle" })
      const tables = await visibleTables(page)
      expect(tables.length).toBeGreaterThan(0)
      for (const table of tables) {
        expect(table.scrollWidth, `${path} table scrolls at ${width}px`).toBeLessThanOrEqual(table.clientWidth + 1)
        expect(table.pinnedRight, `${path} table has no pinned asset column`).not.toBeNull()
      }
      // One pinned-edge position per page: every table's pinned column ends at the same x.
      expect(new Set(tables.map((table) => table.pinnedRight)).size).toBe(1)
    })
  }
}

test("below the min width the asset column stays pinned while the data columns scroll", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 900 })
  await page.goto("/borrow", { waitUntil: "networkidle" })
  await visibleTables(page)
  const table = page.locator("table").first()
  const scroller = table.locator("xpath=..")
  const pinned = table.locator("thead th.sticky").first()

  await expect(page.getByRole("button", { name: "Scroll table right" }).first()).toBeVisible()
  await scroller.evaluate((element) => {
    element.scrollLeft = 200
  })

  // The leading # column has scrolled away; the asset column sticks to the table's left edge.
  const [pinnedBox, scrollerBox] = await Promise.all([pinned.boundingBox(), scroller.boundingBox()])
  expect(pinnedBox?.x).toBeCloseTo(scrollerBox?.x ?? -1, 0)
  await expect(page.getByRole("button", { name: "Scroll table left" }).first()).toBeEnabled()
})
