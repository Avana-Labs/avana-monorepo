"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { useEffect, useRef, useState } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { AskAssistantTrigger } from "./ask-assistant-trigger"
import { HeaderBrand, MobileHeaderBrand } from "./header-brand"
import HeaderDesktopNavigation from "./header-desktop-navigation"
import { LazyMobileMenu } from "./lazy-mobile-menu"
import { LazySearchCommand, LazySearchCommandIconOnly } from "./lazy-search-command"
import { personalDesktopHeaderLinks } from "./site-nav"
import { WalletControl } from "@/app/components/wallet-control"
import { DesktopPreferenceControls } from "./desktop-preference-trigger"
import { cn } from "@/lib/utils"
import { useNavigationPrefetch } from "./navigation-prefetch"

export function Header() {
  const pathname = usePathname()
  const { t } = useTranslation()
  // Warm eligible routes only after the current page loads and the connection allows it.
  const { isSignedIn } = useSiweAuth()
  const prefetchNavigation = useNavigationPrefetch(isSignedIn)
  const desktopLinks = personalDesktopHeaderLinks
  const [mounted, setMounted] = useState(false)
  const [showDivider, setShowDivider] = useState(false)
  const [megaMenuOpen, setMegaMenuOpen] = useState(false)
  const headerRef = useRef<HTMLElement | null>(null)
  const renderMobileBrand = () => <MobileHeaderBrand />
  const renderMobileActions = () => (
    <>
      <span className="flex items-center">
        <LazySearchCommandIconOnly tone="brand" />
      </span>
      <span className="-me-1 flex items-center">
        <AskAssistantTrigger iconOnly tone="brand" />
      </span>
      <span className="flex items-center">
        <WalletControl size="mobile" />
      </span>
    </>
  )

  useEffect(() => {
    setMounted(true)
  }, [])

  // Main chrome: divider only after the page scrolls past the header.
  // Ask / action flow headers keep a permanent border-b on their own sticky bars.
  // Use border-b (not inset shadow) so the line stays visible above the inner
  // chrome rows on mobile — inset shadows paint under descendant content.
  useEffect(() => {
    if (!mounted) return

    const header = headerRef.current
    let threshold = header?.offsetHeight ?? 56
    let pendingOffset = 0
    let frame: number | null = null

    const readScrollOffset = (target?: EventTarget | null) => {
      if (target instanceof HTMLElement) {
        return target.scrollTop
      }

      return Math.max(window.scrollY, document.documentElement.scrollTop, document.body.scrollTop)
    }

    const commitDivider = () => {
      frame = null
      setShowDivider(pendingOffset > threshold)
    }

    const updateDivider = (event?: Event) => {
      pendingOffset = readScrollOffset(event?.target)
      if (frame === null) frame = window.requestAnimationFrame(commitDivider)
    }

    updateDivider()
    const resizeObserver =
      header && typeof ResizeObserver !== "undefined"
        ? new ResizeObserver(() => {
            threshold = header.offsetHeight
            updateDivider()
          })
        : null
    if (resizeObserver && header) resizeObserver.observe(header)
    window.addEventListener("scroll", updateDivider, { passive: true })
    document.addEventListener("scroll", updateDivider, { capture: true, passive: true })

    return () => {
      resizeObserver?.disconnect()
      if (frame !== null) window.cancelAnimationFrame(frame)
      window.removeEventListener("scroll", updateDivider)
      document.removeEventListener("scroll", updateDivider, true)
    }
  }, [mounted])

  const renderPrimaryLinks = (compact: boolean) =>
    desktopLinks.slice(0, 4).map((link) => {
      const isActive = pathname === link.href || pathname.startsWith(`${link.href}/`)
      const Icon = link.icon

      return (
        <Link
          key={link.href}
          href={link.href}
          prefetch={prefetchNavigation(link.href)}
          aria-label={t(link.label)}
          title={t(link.label)}
          className={`inline-flex shrink-0 items-center rounded-full font-sans text-[15px] font-normal leading-5 transition-colors ${
            compact ? "px-2.5 py-1.5" : "px-3 py-2"
          } ${isActive ? "text-foreground" : "text-muted-foreground hover:text-foreground"}`}
        >
          {Icon ? (
            <span className="me-2 inline-flex h-5 w-5 items-center justify-center text-current">
              <Icon className="h-[18px] w-[18px] shrink-0" strokeWidth={2} />
            </span>
          ) : null}
          <span className="whitespace-nowrap">{t(link.label)}</span>
        </Link>
      )
    })

  const renderUtilityLinks = (compact: boolean) =>
    desktopLinks.slice(4).map((link) => {
      const isActive = pathname.startsWith(link.href)
      const Icon = link.icon

      return (
        <Link
          key={link.href}
          href={link.href}
          prefetch={prefetchNavigation(link.href)}
          aria-label={t(link.label)}
          title={t(link.label)}
          className={`group inline-flex shrink-0 items-center rounded-full font-sans text-[15px] font-normal leading-5 transition-colors ${
            compact ? "px-1.5 py-1.5" : "px-2.5 py-2"
          } ${
            isActive
              ? "text-brand dark:text-[#7DDCFF]"
              : "text-muted-foreground hover:text-brand dark:hover:text-[#7DDCFF]"
          }`}
        >
          {Icon ? (
            <span
              className={`inline-flex shrink-0 items-center justify-center text-current transition-transform duration-200 ease-out group-hover:-translate-y-[1px] ${
                compact ? "h-9 w-9" : "me-1.5 h-6 w-6"
              }`}
            >
              <Icon className="h-5 w-5 shrink-0" strokeWidth={2} />
            </span>
          ) : null}
          {compact ? null : <span className="whitespace-nowrap">{t(link.label)}</span>}
        </Link>
      )
    })

  return (
    <header
      ref={headerRef}
      className={cn(
        "sticky top-0 z-40 flex h-14 items-center border-b bg-background text-foreground transition-[border-color] duration-200",
        mounted && (showDivider || megaMenuOpen) ? "border-border" : "border-transparent",
      )}
    >
      {/* Full desktop: sides hug content so long locales can't clip labels; search flexes. */}
      <div className="hidden h-full min-w-0 flex-1 min-[1440px]:block">
        <div className="grid h-full w-full grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3 px-4 sm:px-6 lg:px-5 xl:px-6 2xl:px-8">
          <div className="flex shrink-0 items-center gap-4 2xl:gap-5">
            <Link
              href="/"
              aria-label={t("Home")}
              title={t("Home")}
              className="inline-flex min-w-0 shrink-0 items-center"
            >
              <HeaderBrand />
            </Link>

            <HeaderDesktopNavigation isSignedIn={isSignedIn} onOpenChange={setMegaMenuOpen} />
          </div>

          <div className="flex min-w-0 justify-center px-1">
            <div className="w-full min-w-0 max-w-[380px]">
              <LazySearchCommand />
            </div>
          </div>

          <div className="flex shrink-0 items-center justify-end gap-2">
            <div className="flex items-center gap-0.5 whitespace-nowrap">{renderUtilityLinks(false)}</div>

            <div className="flex shrink-0 items-center gap-2">
              <DesktopPreferenceControls />
              <div className="flex shrink-0">
                <WalletControl size="desktop" />
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* iPad / mid laptop (lg–1439px): compact desktop chrome, not the phone menu. */}
      <div className="hidden h-full min-w-0 flex-1 lg:block min-[1440px]:hidden">
        <div className="grid h-full w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-4 sm:px-6 lg:px-5 xl:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <Link
              href="/"
              aria-label={t("Home")}
              title={t("Home")}
              className="inline-flex min-w-0 shrink-0 items-center"
            >
              <HeaderBrand />
            </Link>

            <nav
              aria-label={t("Primary")}
              className="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto whitespace-nowrap [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
            >
              {renderPrimaryLinks(true)}
            </nav>
          </div>

          <div className="flex shrink-0 items-center justify-end gap-1.5">
            <div className="flex items-center gap-0.5">{renderUtilityLinks(true)}</div>

            <div className="flex shrink-0 items-center gap-1.5">
              <span className="flex items-center">
                <LazySearchCommandIconOnly />
              </span>
              <span className="flex items-center">
                <AskAssistantTrigger iconOnly />
              </span>
              <DesktopPreferenceControls />
              <div className="flex shrink-0">
                <WalletControl size="desktop" />
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Phone / portrait tablet */}
      <div className="h-full min-w-0 flex-1 lg:hidden">
        {/* No local bg — the sticky header already paints background; a fill here
            would cover the shared inset divider that desktop uses after scroll. */}
        <div className="relative flex h-full w-full items-center justify-between px-4 text-foreground sm:px-6">
          <div className="flex items-center gap-3">
            <Link href="/" aria-label={t("Home")} title={t("Home")} className="inline-flex items-center">
              {renderMobileBrand()}
            </Link>

            <LazyMobileMenu />
          </div>

          <div className="flex items-center gap-0.5">{renderMobileActions()}</div>
        </div>
      </div>
    </header>
  )
}
