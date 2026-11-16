import type { LucideIcon } from "@/app/components/icons"

type DesktopHeaderLink = {
  href: string
  label: string
  icon?: LucideIcon
}

// Labels are translated at the header callsite (header.tsx wraps them in t()).
// The header's product links, in order: Swap (the homepage's swap box, at "/"), Lend, Borrow and
// Dashboard, all plain text links. Ask AI sits beside Preferences instead (header.tsx).
export const PRIMARY_HEADER_LINK_COUNT = 4

export const personalDesktopHeaderLinks: DesktopHeaderLink[] = [
  { href: "/", label: "Swap" },
  { href: "/lend", label: "Lend" },
  { href: "/borrow", label: "Borrow" },
  { href: "/dashboard", label: "Dashboard" },
]
