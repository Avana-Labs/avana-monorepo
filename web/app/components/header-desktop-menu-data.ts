import { personalDesktopHeaderLinks } from "./site-nav"

// The desktop mega-menu is scoped to the product routes. IDs must stay in sync with the
// panel configs in header-desktop-menu-panel.tsx and the trigger wiring in
// header-desktop-navigation.tsx.
export type DesktopMenuId = "lend" | "borrow" | "multiply"

const PRODUCT_HREFS: Record<string, DesktopMenuId> = {
  "/lend": "lend",
  "/borrow": "borrow",
  "/multiply": "multiply",
}

// Product links upgraded to mega-menu triggers; anything unlisted renders as an ordinary
// pill link, so panels can ship one at a time.
const desktopMenusWithPanel: readonly DesktopMenuId[] = ["lend", "borrow", "multiply"]

// Express + the three products. Utility links (Dashboard, Umbrella) stay right, owned by the header.
export const desktopPrimaryLinks = personalDesktopHeaderLinks.slice(0, 4)

export function menuIdForHref(href: string): DesktopMenuId | null {
  return PRODUCT_HREFS[href] ?? null
}

export function hasPanel(id: DesktopMenuId | null): id is DesktopMenuId {
  return id !== null && desktopMenusWithPanel.includes(id)
}
