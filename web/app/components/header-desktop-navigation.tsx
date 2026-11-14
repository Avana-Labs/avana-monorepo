"use client"

import dynamic from "next/dynamic"
import Link from "next/link"
import { usePathname, useSearchParams } from "next/navigation"
import { useCallback, useEffect, useRef, useState } from "react"
import {
  desktopPrimaryLinks,
  hasPanel,
  menuIdForHref,
  type DesktopMenuId,
} from "@/app/components/header-desktop-menu-data"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useNavigationPrefetch } from "./navigation-prefetch"

const DeferredHeaderDesktopMenuPanel = dynamic(() => import("@/app/components/header-desktop-menu-panel"), {
  ssr: false,
})

let desktopMenuPanelPromise: Promise<unknown> | null = null

function warmDesktopMenuPanel() {
  desktopMenuPanelPromise ??= import("@/app/components/header-desktop-menu-panel")
}

const PILL_CLASS =
  "site-header-nav-pill inline-flex shrink-0 items-center rounded-full font-sans text-[15px] font-normal leading-5 transition-colors px-3 py-2 outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background"

const DESKTOP_MENU_OPEN_DELAY_MS = 90
const DESKTOP_MENU_CLOSE_DELAY_MS = 180

function isActiveHref(pathname: string, href: string) {
  return pathname === href || pathname.startsWith(`${href}/`)
}

export default function HeaderDesktopNavigation({
  isSignedIn = false,
  onOpenChange,
}: {
  isSignedIn?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const prefetchNavigation = useNavigationPrefetch(isSignedIn)
  const { t } = useTranslation()
  const pathname = usePathname() || "/"
  const searchParams = useSearchParams()
  const searchParamsKey = searchParams?.toString() ?? ""
  const [desktopMenuOpen, setDesktopMenuOpen] = useState<DesktopMenuId | null>(null)
  const [desktopMenuRendered, setDesktopMenuRendered] = useState<DesktopMenuId | null>(null)
  const [focusPanel, setFocusPanel] = useState(false)
  const desktopOpenTimeoutRef = useRef<number | null>(null)
  const desktopCloseTimeoutRef = useRef<number | null>(null)
  const navigationRef = useRef<HTMLElement>(null)
  const handleDesktopMenuExited = useCallback(() => setDesktopMenuRendered(null), [])

  const clearDesktopOpenTimeout = () => {
    if (desktopOpenTimeoutRef.current !== null) {
      window.clearTimeout(desktopOpenTimeoutRef.current)
      desktopOpenTimeoutRef.current = null
    }
  }

  const clearDesktopCloseTimeout = () => {
    if (desktopCloseTimeoutRef.current !== null) {
      window.clearTimeout(desktopCloseTimeoutRef.current)
      desktopCloseTimeoutRef.current = null
    }
  }

  const openDesktopMenu = (menuId: DesktopMenuId) => {
    warmDesktopMenuPanel()
    clearDesktopOpenTimeout()
    clearDesktopCloseTimeout()
    // Dismiss any other open header layer (e.g. the Global preferences popover). Dispatching
    // inside the nav closes radix's dismissable layer while our own outside-close ignores it.
    navigationRef.current?.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }))
    setDesktopMenuRendered(menuId)
    setDesktopMenuOpen(menuId)
  }

  const scheduleDesktopMenuOpen = (menuId: DesktopMenuId) => {
    warmDesktopMenuPanel()
    clearDesktopOpenTimeout()
    clearDesktopCloseTimeout()
    desktopOpenTimeoutRef.current = window.setTimeout(() => {
      openDesktopMenu(menuId)
      desktopOpenTimeoutRef.current = null
    }, DESKTOP_MENU_OPEN_DELAY_MS)
  }

  const scheduleDesktopMenuClose = () => {
    clearDesktopOpenTimeout()
    clearDesktopCloseTimeout()
    desktopCloseTimeoutRef.current = window.setTimeout(() => {
      setDesktopMenuOpen(null)
      desktopCloseTimeoutRef.current = null
    }, DESKTOP_MENU_CLOSE_DELAY_MS)
  }

  const closeDesktopMenu = () => {
    clearDesktopOpenTimeout()
    clearDesktopCloseTimeout()
    setDesktopMenuOpen(null)
  }

  useEffect(
    () => () => {
      clearDesktopOpenTimeout()
      clearDesktopCloseTimeout()
    },
    [],
  )

  // Surface the open state so the header can show its divider line while a panel is open.
  useEffect(() => {
    onOpenChange?.(desktopMenuOpen !== null)
  }, [desktopMenuOpen, onOpenChange])

  // Close the panel when the route or its query changes — the persistent header must not keep a
  // panel open after a trigger link, a market row, or "View all" navigates.
  useEffect(() => {
    setDesktopMenuOpen(null)
  }, [pathname, searchParamsKey])

  useEffect(() => {
    if (!desktopMenuOpen) return
    const panelId = `desktop-menu-${desktopMenuOpen}`
    const isInside = (target: EventTarget | null) =>
      target instanceof Node &&
      Boolean(navigationRef.current?.contains(target) || document.getElementById(panelId)?.contains(target))
    const dismissOutside = (event: Event) => {
      if (!isInside(event.target)) setDesktopMenuOpen(null)
    }
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return
      event.preventDefault()
      setDesktopMenuOpen(null)
      navigationRef.current?.querySelector<HTMLElement>(`[aria-controls="${panelId}"]`)?.focus()
    }
    document.addEventListener("keydown", escape)
    document.addEventListener("pointerdown", dismissOutside)
    document.addEventListener("focusin", dismissOutside)
    return () => {
      document.removeEventListener("keydown", escape)
      document.removeEventListener("pointerdown", dismissOutside)
      document.removeEventListener("focusin", dismissOutside)
    }
  }, [desktopMenuOpen])

  return (
    <>
      <nav
        ref={navigationRef}
        aria-label={t("Primary")}
        className="flex items-center gap-0.5 whitespace-nowrap"
        onMouseEnter={warmDesktopMenuPanel}
        onMouseLeave={scheduleDesktopMenuClose}
      >
        {desktopPrimaryLinks.map((link) => {
          const menuId = menuIdForHref(link.href)
          const isSection = isActiveHref(pathname, link.href)

          if (menuId && hasPanel(menuId)) {
            const isOpen = desktopMenuOpen === menuId
            const isHighlighted = isOpen || isSection
            return (
              <Link
                key={link.href}
                href={link.href}
                prefetch={prefetchNavigation(link.href)}
                aria-haspopup="true"
                aria-expanded={isOpen}
                aria-controls={`desktop-menu-${menuId}`}
                onMouseEnter={() => {
                  setFocusPanel(false)
                  scheduleDesktopMenuOpen(menuId)
                }}
                onFocus={warmDesktopMenuPanel}
                onKeyDown={(event) => {
                  if (event.key !== "ArrowDown") return
                  event.preventDefault()
                  setFocusPanel(true)
                  openDesktopMenu(menuId)
                }}
                className={`${PILL_CLASS} ${isHighlighted ? "text-foreground" : "text-muted-foreground hover:text-foreground"}`}
              >
                <span className="whitespace-nowrap">{t(link.label)}</span>
              </Link>
            )
          }

          return (
            <Link
              key={link.href}
              href={link.href}
              prefetch={prefetchNavigation(link.href)}
              onMouseEnter={closeDesktopMenu}
              onFocus={closeDesktopMenu}
              className={`${PILL_CLASS} ${isSection ? "text-foreground" : "text-muted-foreground hover:text-foreground"}`}
            >
              <span className="whitespace-nowrap">{t(link.label)}</span>
            </Link>
          )
        })}
      </nav>

      {desktopMenuRendered !== null ? (
        <DeferredHeaderDesktopMenuPanel
          menuId={desktopMenuRendered}
          isOpen={desktopMenuOpen !== null}
          onOpen={clearDesktopCloseTimeout}
          onClose={scheduleDesktopMenuClose}
          onExited={handleDesktopMenuExited}
          focusOnOpen={focusPanel}
        />
      ) : null}
    </>
  )
}
