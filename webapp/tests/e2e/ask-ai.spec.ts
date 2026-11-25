import { expect, test } from "@playwright/test"

test.describe("Ask AI acceptance", () => {
  test("keeps the Base shell and sidebar controls stable", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await page.goto("/ask")
    await expect(page.getByRole("main")).toBeVisible()
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      /Good morning!|Good afternoon!|Good evening!|Welcome back!|Hey!|Morning,|Afternoon,|Evening,|Hey,/,
    )
    await expect(page.getByLabel("Ask Avana a question")).toBeVisible()
    await expect(page.getByRole("button", { name: "Add attachment" })).toHaveCount(0)

    const toggle = page.getByRole("button", { name: /sidebar/i }).first()
    await expect(toggle).toHaveAccessibleName(/Hide sidebar|Open sidebar/)
    await toggle.click()
    await expect(toggle).toHaveAccessibleName(/Hide sidebar|Open sidebar/)
    await toggle.click()
    await expect(page.getByRole("button", { name: /New Thread/i })).toBeVisible()
  })

  test("preserves the caret while editing the middle of a draft", async ({ page }) => {
    await page.goto("/ask")
    const composer = page.getByLabel("Ask Avana a question")
    await composer.fill("ABCDE")
    await composer.evaluate((element: HTMLTextAreaElement) => element.setSelectionRange(2, 2))
    await composer.press("Delete")
    await expect(composer).toHaveValue("ABDE")
    await expect.poll(() => composer.evaluate((element: HTMLTextAreaElement) => element.selectionStart)).toBe(2)
  })

  test("renders user turns as compact right-aligned bubbles", async ({ page }) => {
    test.skip(!process.env.RUN_ASK_AI_CONVEX_E2E, "requires the branch Convex schema to be deployed")
    await page.goto("/ask")
    const composer = page.getByLabel("Ask Avana a question")
    await expect(composer).toBeVisible()
    await composer.fill("Hi")
    await expect(page.getByRole("button", { name: "Send message" })).toBeEnabled()
    await page.getByRole("button", { name: "Send message" }).click()
    const userTurn = page.getByText("Hi", { exact: true }).last()
    await expect(userTurn).toBeVisible()
    const box = await userTurn.boundingBox()
    const viewport = page.viewportSize()
    expect(box).not.toBeNull()
    expect(viewport).not.toBeNull()
    expect(box!.width).toBeLessThan(180)
    expect(box!.x + box!.width).toBeGreaterThan(viewport!.width / 2)
  })

  test("fits the composer and sidebar controls on a phone viewport", async ({ page }) => {
    test.skip(!process.env.RUN_ASK_AI_CONVEX_E2E, "requires the branch Convex schema to be deployed")
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto("/ask")
    await expect(page.getByLabel("Ask Avana a question")).toBeInViewport()
    await expect(page.getByRole("button", { name: /Open sidebar|Hide sidebar/ }).first()).toBeInViewport()
    await page
      .getByRole("button", { name: /Open sidebar|Hide sidebar/ })
      .first()
      .click()
    await expect(page.getByRole("button", { name: "Close sidebar" })).toBeInViewport()
    await page.getByRole("button", { name: "Close sidebar" }).click()
    await expect(page.locator("body")).not.toHaveCSS("overflow-x", "scroll")
  })
})
