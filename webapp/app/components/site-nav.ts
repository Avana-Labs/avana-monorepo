import type { LucideIcon } from "@/app/components/icons"
import { DashboardSquareAdd } from "@/app/components/icons"

type DesktopHeaderLink = {
  href: string
  label: string
  icon?: LucideIcon
}

// Labels are translated at the header callsite (header.tsx wraps them in t()).
// The first PRIMARY_HEADER_LINK_COUNT links are the product links; the rest (Dashboard) are the
// icon utility links on the right.
export const PRIMARY_HEADER_LINK_COUNT = 3

export const personalDesktopHeaderLinks: DesktopHeaderLink[] = [
  { href: "/", label: "Express" },
  { href: "/lend", label: "Lend" },
  { href: "/borrow", label: "Borrow" },
  { href: "/dashboard", label: "Dashboard", icon: DashboardSquareAdd },
]
