import type { ActionProduct } from "./contracts"

type DashboardTabKey = "wallet" | "lend" | "borrow" | "referrals" | "rewards"

const PRODUCT_TAB: Record<ActionProduct, DashboardTabKey> = {
  borrow: "borrow",
  lend: "lend",
  rewards: "wallet",
}

// Products that own a dedicated top-level surface get sent back there on
// action success — the dashboard tab doesn't reflect their positions yet.
const PRODUCT_SUCCESS_HREF: Partial<Record<ActionProduct, string>> = {}

const PRODUCT_SUCCESS_LABEL: Partial<Record<ActionProduct, string>> = {}

export function dashboardHrefForProduct(product: ActionProduct): string {
  return PRODUCT_SUCCESS_HREF[product] ?? `/dashboard?tab=${PRODUCT_TAB[product]}`
}

export function successDashboardCtaLabel(product: ActionProduct): string {
  return PRODUCT_SUCCESS_LABEL[product] ?? "View dashboard"
}
