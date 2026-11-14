"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import {
  ArrowUpRight,
  Check,
  ChevronLeft,
  ChevronRight,
  CircleHelp,
  Coins,
  Globe2,
  Shield,
  SunMedium,
} from "@/app/components/icons"
import type { ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { Switch } from "@/components/ui/switch"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { CurrencyFlag } from "./currency-flag"
import { CURRENCY_OPTIONS, LANGUAGE_OPTIONS, useLocaleDisplayPreferences } from "./display-preferences"
import { AVANA_EXTERNAL_LINKS } from "./external-links"
import { useTheme } from "./theme-provider"
import { OVERLAY_SCRIM_CLASS } from "./card-surface-tokens"
import { useNavigationPrefetch } from "./navigation-prefetch"
import { MenuToggleIcon } from "./menu-toggle-icon"

const siteRoutes = {
  home: "/",
}

type MobileMenuView = "root" | "language" | "currency" | "network"

type MobileMenuProps = {
  initialOpen?: boolean
}

/**
 * Phone / tablet site menu. It opens BELOW the real header (which stays visible and live: search,
 * Ask AI and the wallet control keep working), and this component's own toggle morphs from three
 * bars to an X in place — there is no second header or separate close button.
 */
export function MobileMenu({ initialOpen = false }: MobileMenuProps) {
  const { isSignedIn } = useSiweAuth()
  const prefetchNavigation = useNavigationPrefetch(isSignedIn)
  const [open, setOpen] = useState(initialOpen)
  const [renderMenu, setRenderMenu] = useState(initialOpen)
  const [isShown, setIsShown] = useState(false)
  const [settingsIntroActive, setSettingsIntroActive] = useState(false)
  const [view, setView] = useState<MobileMenuView>("root")
  const [mounted, setMounted] = useState(false)
  const [sheetDragOffset, setSheetDragOffset] = useState(0)
  const [sheetDragging, setSheetDragging] = useState(false)
  const selectorSheetRef = useRef<HTMLDivElement | null>(null)
  const menuButtonRef = useRef<HTMLButtonElement | null>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const sheetDragStateRef = useRef<{
    pointerId: number
    startY: number
    offset: number
    sheetHeight: number
    moved: boolean
  } | null>(null)
  const pathname = usePathname()
  const previousPathnameRef = useRef(pathname)
  const { resolvedTheme, setTheme } = useTheme()
  const { language, setLanguage, currency, setCurrency } = useLocaleDisplayPreferences()
  const { t } = useTranslation()
  const accentClass = "text-[#01AACF]"

  useEffect(() => {
    setMounted(true)
  }, [])

  useEffect(() => {
    // The lazy trigger mounts this component with initialOpen on the first tap.
    // Close only on an actual navigation, not on that initial mount.
    if (previousPathnameRef.current === pathname) return
    previousPathnameRef.current = pathname
    setOpen(false)
    setRenderMenu(false)
    setIsShown(false)
    setSettingsIntroActive(false)
    setView("root")
    setSheetDragOffset(0)
    setSheetDragging(false)
    sheetDragStateRef.current = null
  }, [pathname])

  useEffect(() => {
    if (!open) {
      if (!renderMenu) {
        setIsShown(false)
        setSettingsIntroActive(false)
      }
      return
    }

    setSettingsIntroActive(true)
    const frame = window.requestAnimationFrame(() => {
      setIsShown(true)
    })
    const timer = window.setTimeout(() => {
      setSettingsIntroActive(false)
    }, 820)

    return () => {
      window.cancelAnimationFrame(frame)
      window.clearTimeout(timer)
    }
  }, [open, renderMenu])

  useEffect(() => {
    if (!renderMenu) {
      return
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false)
        setIsShown(false)
        setSettingsIntroActive(false)
      }
    }

    const previousOverflow = document.body.style.overflow
    const previousPaddingRight = document.body.style.paddingRight
    const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth
    document.body.style.overflow = "hidden"
    if (scrollbarWidth > 0) {
      document.body.style.paddingRight = `${scrollbarWidth}px`
    }
    window.addEventListener("keydown", handleKeyDown)

    return () => {
      document.body.style.overflow = previousOverflow
      document.body.style.paddingRight = previousPaddingRight
      window.removeEventListener("keydown", handleKeyDown)
    }
  }, [renderMenu])

  const onClose = () => {
    setOpen(false)
    setIsShown(false)
    setSettingsIntroActive(false)
    setView("root")
    setSheetDragOffset(0)
    setSheetDragging(false)
    sheetDragStateRef.current = null
    window.setTimeout(() => {
      setRenderMenu(false)
      restoreFocusRef.current?.focus()
    }, 300)
  }

  const onOpen = () => {
    restoreFocusRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : menuButtonRef.current
    setRenderMenu(true)
    window.requestAnimationFrame(() => {
      setOpen(true)
    })
  }

  const mainLinks = [
    {
      href: siteRoutes.home,
      label: "Express",
    },
    {
      href: "/lend",
      label: "Lend",
    },
    {
      href: "/borrow",
      label: "Borrow",
    },
    {
      href: "/dashboard",
      label: "Dashboard",
    },
  ] as const

  const currentLanguage = LANGUAGE_OPTIONS.find((option) => option.code === language) ?? LANGUAGE_OPTIONS[0]
  const currentCurrency = CURRENCY_OPTIONS.find((option) => option.code === currency) ?? CURRENCY_OPTIONS[0]
  const currentNetwork = "Sandbox"
  const lightModeEnabled = mounted ? resolvedTheme === "light" : false
  const isVisible = open && isShown
  const isSelectorSheetOpen = view !== "root"

  const closeSelectorSheet = () => {
    setView("root")
    setSheetDragOffset(0)
    setSheetDragging(false)
    sheetDragStateRef.current = null
  }

  const handleSelectorPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    sheetDragStateRef.current = {
      pointerId: event.pointerId,
      startY: event.clientY,
      offset: sheetDragOffset,
      sheetHeight: selectorSheetRef.current?.offsetHeight ?? 0,
      moved: false,
    }
    setSheetDragging(true)
    event.currentTarget.setPointerCapture(event.pointerId)
    event.preventDefault()
  }

  const handleSelectorPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    const dragState = sheetDragStateRef.current
    if (!dragState || dragState.pointerId !== event.pointerId) {
      return
    }

    const nextOffset = event.clientY - dragState.startY + dragState.offset
    dragState.moved = dragState.moved || Math.abs(nextOffset) > 8
    setSheetDragOffset(Math.min(320, Math.max(0, nextOffset)))
    event.preventDefault()
  }

  const finishSelectorDrag = (shouldClose: boolean, finalOffset: number) => {
    sheetDragStateRef.current = null
    setSheetDragging(false)
    if (shouldClose) {
      setSheetDragOffset(0)
      setView("root")
      return
    }

    setSheetDragOffset(Math.max(0, finalOffset))
  }

  const handleSelectorPointerUp = (event: React.PointerEvent<HTMLDivElement>) => {
    const dragState = sheetDragStateRef.current
    if (!dragState || dragState.pointerId !== event.pointerId) {
      return
    }

    event.currentTarget.releasePointerCapture(event.pointerId)
    const closeThreshold = Math.max(180, dragState.sheetHeight * 0.32)
    finishSelectorDrag(dragState.moved && sheetDragOffset > closeThreshold, sheetDragOffset)
    event.preventDefault()
  }

  const handleSelectorPointerCancel = (event: React.PointerEvent<HTMLDivElement>) => {
    const dragState = sheetDragStateRef.current
    if (!dragState || dragState.pointerId !== event.pointerId) {
      return
    }

    finishSelectorDrag(false, sheetDragOffset)
    event.preventDefault()
  }

  const rootSettingsClass =
    "flex w-full items-center justify-between gap-4 text-start text-[1.2rem] font-medium leading-[1.14] text-foreground"
  const rootSettingsLabelClass = "flex items-center gap-3"
  const rootSettingsIconClass = `h-[1.15rem] w-[1.15rem] stroke-[1.9] ${accentClass}`
  const dividerClass = "border-brand/25 dark:border-brand/35"
  const introDelay = (index: number) => `${120 + index * 35}ms`
  const settingsIntroStyle = (index: number) =>
    settingsIntroActive
      ? {
          animationName: "mobile-menu-item-in",
          animationDuration: "300ms",
          animationTimingFunction: "ease-out",
          animationFillMode: "both" as const,
          animationDelay: introDelay(index),
        }
      : undefined

  function renderRootMenu() {
    return (
      <>
        <ol>
          {mainLinks.map((link, index) => {
            const isActive = pathname === link.href || pathname.startsWith(`${link.href}/`)

            return (
              <li
                key={link.href}
                className={`border-b ${dividerClass} transition-all duration-300 ease-out ${
                  isVisible ? "translate-y-0 opacity-100" : "translate-y-4 opacity-0"
                }`}
                style={{ transitionDelay: introDelay(index) }}
              >
                <Link
                  href={link.href}
                  prefetch={prefetchNavigation(link.href)}
                  onClick={onClose}
                  className="flex items-end justify-between gap-5 py-3"
                >
                  <span
                    className={`text-[clamp(1.5rem,6.1vw,2.1rem)] font-normal leading-[1.04] tracking-[-0.04em] ${
                      isActive ? "text-foreground" : "text-foreground"
                    }`}
                  >
                    {t(link.label)}
                  </span>
                  <span
                    aria-hidden="true"
                    className="shrink-0 pb-0.5 text-[0.88rem] font-medium tracking-[-0.02em] text-[#01AACF]"
                  >
                    {String(index + 1).padStart(2, "0")}
                  </span>
                </Link>
              </li>
            )
          })}
        </ol>

        <ul className="mt-8 space-y-5">
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length)}>
            <button type="button" onClick={() => setView("language")} className={rootSettingsClass}>
              <span className={rootSettingsLabelClass}>
                <Globe2 className={rootSettingsIconClass} />
                <span>{t("Language")}</span>
              </span>
              <span className="flex items-center gap-2 text-[1rem] text-muted-foreground">
                {currentLanguage.label}
                <ChevronRight className="h-[1.1rem] w-[1.1rem] text-muted-foreground" />
              </span>
            </button>
          </li>
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length + 1)}>
            <button type="button" onClick={() => setView("currency")} className={rootSettingsClass}>
              <span className={rootSettingsLabelClass}>
                <Coins className={rootSettingsIconClass} />
                <span>{t("Currency")}</span>
              </span>
              <span className="flex items-center gap-2 text-[1rem] text-muted-foreground">
                {currentCurrency.code}
                <ChevronRight className="h-[1.1rem] w-[1.1rem] text-muted-foreground" />
              </span>
            </button>
          </li>
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length + 2)}>
            <button type="button" onClick={() => setView("network")} className={rootSettingsClass}>
              <span className={rootSettingsLabelClass}>
                <Globe2 className={rootSettingsIconClass} />
                <span>{t("Network")}</span>
              </span>
              <span className="flex items-center gap-2 text-[1rem] text-muted-foreground">
                <span>{currentNetwork}</span>
                <ChevronRight className="h-[1.1rem] w-[1.1rem] text-muted-foreground" />
              </span>
            </button>
          </li>
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length + 3)}>
            <div className={rootSettingsClass}>
              <span className={rootSettingsLabelClass}>
                <SunMedium className={rootSettingsIconClass} />
                <span>{t("Light Mode")}</span>
              </span>
              <Switch
                checked={lightModeEnabled}
                onCheckedChange={(checked) => setTheme(checked ? "light" : "dark")}
                aria-label={t("Toggle light mode")}
                className="data-[state=checked]:bg-brand data-[state=unchecked]:bg-brand/35"
              />
            </div>
          </li>
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length + 4)}>
            <Link href="/support-center" prefetch={false} onClick={onClose} className={rootSettingsClass}>
              <span className={rootSettingsLabelClass}>
                <CircleHelp className={rootSettingsIconClass} />
                <span>{t("Help Center")}</span>
              </span>
              <ArrowUpRight className="h-[1.1rem] w-[1.1rem] text-[#01AACF]" />
            </Link>
          </li>
          <li className="translate-y-0 opacity-100" style={settingsIntroStyle(mainLinks.length + 5)}>
            <a
              href={AVANA_EXTERNAL_LINKS.privacy}
              target="_blank"
              rel="noreferrer"
              onClick={onClose}
              className={rootSettingsClass}
            >
              <span className={rootSettingsLabelClass}>
                <Shield className={rootSettingsIconClass} />
                <span>{t("Security & privacy")}</span>
              </span>
              <ArrowUpRight className="h-[1.1rem] w-[1.1rem] text-[#01AACF]" />
            </a>
          </li>
        </ul>
      </>
    )
  }

  function renderPanelHeader(title: string, backView: MobileMenuView) {
    return (
      <div className="mb-5 flex items-center gap-3 border-b border-border px-5 pb-4">
        <button
          type="button"
          onClick={() => {
            if (backView === "root") {
              closeSelectorSheet()
              return
            }
            setView(backView)
          }}
          className="inline-flex h-10 w-10 items-center justify-center rounded-full text-foreground transition hover:bg-hover"
          aria-label={t("Back to menu")}
        >
          <ChevronLeft className="h-6 w-6" />
        </button>
        <h2 className="text-[1.9rem] font-medium leading-none tracking-[-0.04em] text-foreground">{t(title)}</h2>
      </div>
    )
  }

  function renderSelectorSheet(title: string, backView: MobileMenuView, content: ReactNode) {
    return (
      <>
        <button
          type="button"
          aria-label={t("Close {title} sheet").replace("{title}", title.toLowerCase())}
          onClick={closeSelectorSheet}
          className={`absolute inset-0 ${OVERLAY_SCRIM_CLASS} transition-opacity duration-200 ${
            isSelectorSheetOpen ? "opacity-100" : "opacity-0"
          }`}
        />
        <div
          ref={(node) => {
            selectorSheetRef.current = node
          }}
          className={`mobile-bottom-sheet absolute inset-x-0 bottom-0 max-h-[min(82dvh,calc(100dvh-4rem))] overflow-hidden rounded-t-[1.75rem] border border-b-0 border-border bg-background p-0 shadow-[0_-24px_64px_rgba(15,23,42,0.18)] transition-transform duration-300 ease-out ${
            isSelectorSheetOpen ? "translate-y-0" : "translate-y-full"
          } ${sheetDragging ? "mobile-bottom-sheet-dragging" : ""}`}
          style={sheetDragOffset ? { transform: `translateY(${sheetDragOffset}px)` } : undefined}
          role="dialog"
          aria-modal="true"
          aria-label={t(title)}
        >
          <div
            className="mobile-bottom-sheet-handle absolute inset-x-0 top-0 z-10 flex h-10 items-start justify-center pt-3"
            onPointerDown={handleSelectorPointerDown}
            onPointerMove={handleSelectorPointerMove}
            onPointerUp={handleSelectorPointerUp}
            onPointerCancel={handleSelectorPointerCancel}
          >
            <div className="h-1.5 w-[4.5rem] rounded-full bg-foreground/35 shadow-[0_1px_0_rgba(255,255,255,0.18)_inset]" />
          </div>
          {renderPanelHeader(title, backView)}
          <div className="max-h-[calc(min(82dvh,calc(100dvh-4rem))-6.5rem)] overflow-y-auto px-3 pb-[calc(1rem+env(safe-area-inset-bottom))]">
            {content}
          </div>
        </div>
      </>
    )
  }

  function renderLanguageList() {
    return renderSelectorSheet(
      "Language",
      "root",
      <ul className="space-y-1">
        {LANGUAGE_OPTIONS.map((option) => (
          <li key={option.code}>
            <button
              type="button"
              onClick={() => {
                setLanguage(option.code)
                closeSelectorSheet()
              }}
              className="flex w-full items-center justify-between gap-4 rounded-radius-lg px-3 py-4 text-start"
            >
              <span className="text-[1.15rem] font-medium leading-tight text-foreground">{option.label}</span>
              {option.code === language ? <Check className="h-6 w-6 text-brand" /> : null}
            </button>
          </li>
        ))}
      </ul>,
    )
  }

  function renderCurrencyList() {
    return renderSelectorSheet(
      "Currency",
      "root",
      <ul className="space-y-1">
        {CURRENCY_OPTIONS.map((option) => (
          <li key={option.code}>
            <button
              type="button"
              onClick={() => {
                setCurrency(option.code)
                closeSelectorSheet()
              }}
              className="flex w-full items-center justify-between gap-4 rounded-radius-lg px-3 py-4 text-start"
            >
              <span className="flex items-center gap-4">
                <CurrencyFlag code={option.code} className="h-6 w-6" />
                <span className="text-[1.15rem] font-medium leading-tight text-foreground">{option.label}</span>
              </span>
              {option.code === currency ? <Check className="h-6 w-6 text-brand" /> : null}
            </button>
          </li>
        ))}
      </ul>,
    )
  }

  function renderNetworkList() {
    return renderSelectorSheet(
      "Network",
      "root",
      <ul className="space-y-1">
        <li>
          <button
            type="button"
            className="flex w-full items-center justify-between gap-4 rounded-radius-lg px-3 py-4 text-start"
            onClick={closeSelectorSheet}
          >
            <span className="text-[1.15rem] font-medium leading-tight text-foreground">{t("Sandbox")}</span>
            <Check className="h-6 w-6 text-brand" />
          </button>
        </li>
        {["Ethereum", "Avalanche", "Base", "Arbitrum", "Robinhood"].map((network) => (
          <li key={network}>
            <div className="flex w-full items-center justify-between gap-4 rounded-radius-lg px-3 py-4 text-start opacity-70">
              <span className="text-[1.15rem] font-medium leading-tight text-foreground">{network}</span>
              <span className="text-[0.82rem] text-muted-foreground">{t("Unavailable")}</span>
            </div>
          </li>
        ))}
      </ul>,
    )
  }

  return (
    <>
      <button
        ref={menuButtonRef}
        type="button"
        className="inline-flex h-10 w-10 items-center justify-center text-[#01AACF] transition hover:text-[#01AACF]/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 [-webkit-tap-highlight-color:transparent] xl:hidden"
        aria-label={t("Toggle menu")}
        aria-expanded={open}
        aria-controls="mobile-site-nav"
        onClick={() => {
          if (open) {
            onClose()
            return
          }
          onOpen()
        }}
      >
        {/* Follows `isVisible` (a frame after mount), so a lazy first open still animates. */}
        <MenuToggleIcon open={isVisible} />
        <span className="sr-only">{t("Toggle menu")}</span>
      </button>

      {renderMenu ? (
        <div
          className={`fixed inset-x-0 bottom-0 top-14 z-[60] bg-background text-foreground transition-opacity duration-300 ease-out xl:hidden ${
            isVisible ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0"
          }`}
          role="dialog"
          aria-label={t("Mobile menu")}
        >
          <nav
            id="mobile-site-nav"
            aria-label={t("Mobile navigation")}
            className={`h-full overflow-y-auto px-4 pb-10 pt-10 transition-all duration-300 ease-out sm:px-6 ${
              isVisible ? "translate-y-0 opacity-100" : "translate-y-3 opacity-0"
            } ${isSelectorSheetOpen ? "pointer-events-none opacity-35 blur-[1px]" : ""}`}
          >
            {renderRootMenu()}
          </nav>

          {view === "language" ? renderLanguageList() : null}
          {view === "currency" ? renderCurrencyList() : null}
          {view === "network" ? renderNetworkList() : null}
        </div>
      ) : null}
    </>
  )
}
