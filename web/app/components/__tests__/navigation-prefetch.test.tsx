import type { AnchorHTMLAttributes } from "react"
import { cleanup, render } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { Header } from "../header"
import { MobileMenu } from "../mobile-menu"
import { shouldPrefetchNavigation } from "../navigation-prefetch"

const session = vi.hoisted(() => ({ isSignedIn: false }))
const route = vi.hoisted(() => ({ pathname: "/" }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useSiweAuth: () => session }))
vi.mock("next/navigation", () => ({ usePathname: () => route.pathname, useSearchParams: () => new URLSearchParams() }))
vi.mock("next/link", () => ({
  default: ({ prefetch, ...props }: AnchorHTMLAttributes<HTMLAnchorElement> & { prefetch?: boolean }) => (
    <a {...props} data-prefetch={String(prefetch)} />
  ),
}))
vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (text: string) => text }) }))
vi.mock("../ask-assistant-trigger", () => ({ AskAssistantTrigger: () => null }))
vi.mock("../lazy-mobile-menu", () => ({ LazyMobileMenu: () => null }))
vi.mock("../lazy-search-command", () => ({ LazySearchCommand: () => null, LazySearchCommandIconOnly: () => null }))
vi.mock("../wallet-control", () => ({ WalletControl: () => null }))
vi.mock("../desktop-preference-trigger", () => ({ DesktopPreferenceControls: () => null }))
vi.mock("../theme-provider", () => ({ useTheme: () => ({ resolvedTheme: "light", setTheme: vi.fn() }) }))
vi.mock("../display-preferences", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../display-preferences")>()),
  useLocaleDisplayPreferences: () => ({ language: "en", currency: "USD", setLanguage: vi.fn(), setCurrency: vi.fn() }),
}))

afterEach(() => {
  cleanup()
  route.pathname = "/"
})

it("keeps the lazy menu open on its first tap and closes it after navigation", () => {
  const { container, rerender } = render(<MobileMenu initialOpen />)
  expect(container.querySelector('[role="dialog"]')).not.toBeNull()
  route.pathname = "/lend"
  rerender(<MobileMenu initialOpen />)
  expect(container.querySelector('[role="dialog"]')).toBeNull()
})

describe.each([false, true])("navigation prefetch with signed-in=%s", (isSignedIn) => {
  it.each(["desktop", "mobile"])("warms full product routes only for signed-in %s users", (surface) => {
    session.isSignedIn = isSignedIn
    const { container } = render(surface === "desktop" ? <Header /> : <MobileMenu initialOpen />)
    for (const href of ["/borrow", "/lend", "/multiply", "/dashboard", "/umbrella"]) {
      const links = container.querySelectorAll(`a[href="${href}"]`)
      expect(links.length).toBeGreaterThan(0)
      for (const link of links) {
        expect(link).toHaveAttribute("data-prefetch", String(shouldPrefetchNavigation(href, isSignedIn)))
      }
    }
  })
})

it("does not eagerly prefetch heavy product catalogs", () => {
  for (const href of ["/borrow", "/lend", "/multiply"]) {
    expect(shouldPrefetchNavigation(href, true)).toBe(false)
  }
  expect(shouldPrefetchNavigation("/dashboard", true)).toBe(true)
  expect(shouldPrefetchNavigation("/borrow", false)).toBe(false)
})
