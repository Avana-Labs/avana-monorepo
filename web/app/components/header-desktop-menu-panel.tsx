"use client"

import Link from "next/link"
import { useEffect, useRef, useState } from "react"
import { TokenIcon } from "@/app/components/token-icon"
import { OVERLAY_SCRIM_CLASS } from "@/app/components/card-surface-tokens"
import type { DesktopMenuId } from "@/app/components/header-desktop-menu-data"
import { useTranslation } from "@/app/lib/i18n/use-translation"

interface PanelRow {
  /** Symbol used for the (primary) token icon. */
  symbol: string
  /** Second symbol — renders an overlapping pair (pool / loop markets). */
  symbol2?: string
  /** Bold display label; defaults to `symbol` (loop markets show a collateral/asset pair). */
  label?: string
  name?: string
  metric: string
  /** Colours the metric green (positive) / red (negative) for signed returns; neutral if unset. */
  metricTone?: "positive" | "negative"
  /** Per-market detail page. */
  href: string
}

interface PanelColumn {
  title: string
  /** Product page with this column's category chip preselected. */
  viewAllHref: string
  rows: PanelRow[]
}

interface PanelConfig {
  /** One-line intro shown at the top of the rail. */
  tagline: string
  /** The intro CTA target (the product landing page) and its label. */
  browseHref: string
  browseLabel: string
  /** Right-aligned metric label for each column (e.g. APY / APR / Net APY). */
  metricLabel: string
  columns: PanelColumn[]
}

// The columns list markets from services/convex once the header can read them; until then the
// panel shows its intro and the link to the product page only.
function lendColumns(): PanelColumn[] {
  return []
}

function borrowColumns(): PanelColumn[] {
  return []
}

function usePanelConfig(menuId: DesktopMenuId): PanelConfig | null {
  const { t } = useTranslation()
  if (menuId === "lend") {
    return {
      tagline: t("Supply capital into Hub-connected lending markets and earn from LP-backed borrower demand."),
      browseHref: "/lend",
      browseLabel: t("Browse Lend Page"),
      metricLabel: t("APY"),
      columns: lendColumns(),
    }
  }
  if (menuId === "borrow") {
    return {
      tagline: t(
        "Turn your liquidity pool positions into collateral and borrow against them here without leaving the pool.",
      ),
      browseHref: "/borrow",
      browseLabel: t("Browse Borrow Page"),
      metricLabel: t("APR"),
      columns: borrowColumns(),
    }
  }
  return null
}

interface HeaderDesktopMenuPanelProps {
  menuId: DesktopMenuId
  isOpen: boolean
  onOpen: () => void
  onClose: () => void
  onExited: () => void
  focusOnOpen: boolean
}

const DESKTOP_MENU_TRANSITION_MS = 300

export default function HeaderDesktopMenuPanel({
  menuId,
  isOpen,
  onOpen,
  onClose,
  onExited,
  focusOnOpen,
}: HeaderDesktopMenuPanelProps) {
  const { t } = useTranslation()
  const panelRef = useRef<HTMLDivElement>(null)
  const config = usePanelConfig(menuId)
  const [isShown, setIsShown] = useState(false)

  // Double requestAnimationFrame gate: mount in the closed state, then flip to shown so the
  // browser has a real starting frame to transition from (otherwise it snaps open). Runs only on
  // open/close — switching between product menus keeps the panel shown, so the content swaps
  // without blanking and re-fading.
  useEffect(() => {
    if (!isOpen) {
      setIsShown(false)
      const exitTimeout = window.setTimeout(onExited, DESKTOP_MENU_TRANSITION_MS + 20)
      return () => window.clearTimeout(exitTimeout)
    }
    let raf2 = 0
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => setIsShown(true))
    })
    return () => {
      cancelAnimationFrame(raf1)
      cancelAnimationFrame(raf2)
    }
  }, [isOpen, onExited])

  useEffect(() => {
    if (isShown && focusOnOpen) panelRef.current?.querySelector<HTMLElement>("a")?.focus()
  }, [isShown, focusOnOpen])

  if (!config) return null

  const numColumns = config.columns.length
  const itemClass = `transition-[opacity,transform] duration-300 ease-out ${
    isShown ? "translate-y-0 opacity-100" : "-translate-y-2 opacity-0"
  }`
  const itemDelay = (delay: number) => ({ transitionDelay: isShown ? `${delay}ms` : "0ms" })

  return (
    <>
      {/* Backdrop blur behind the panel — mirrors the desktop search dialog overlay. */}
      <div
        aria-hidden="true"
        onMouseEnter={onClose}
        className={`fixed inset-x-0 bottom-0 top-14 z-20 hidden ${OVERLAY_SCRIM_CLASS} transition-opacity duration-300 ease-out min-[1440px]:block ${
          isShown ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0"
        }`}
      />
      <div
        id={`desktop-menu-${menuId}`}
        ref={panelRef}
        inert={!isShown}
        aria-hidden={!isShown}
        onMouseEnter={onOpen}
        onMouseLeave={onClose}
        className={`fixed inset-x-0 top-14 z-30 hidden origin-top transform-gpu transition-[opacity,transform] duration-300 ease-out min-[1440px]:block ${
          isShown
            ? "pointer-events-auto translate-y-0 scale-y-100 opacity-100"
            : "pointer-events-none -translate-y-2 scale-y-[0.98] opacity-0"
        }`}
      >
        <div className="border-b border-border bg-background">
          <div className="mx-auto w-full max-w-[1320px] px-6 py-7 2xl:px-8">
            <div className="grid gap-x-10 gap-y-8 lg:grid-cols-[minmax(0,15rem)_minmax(0,1fr)]">
              {/* Intro rail */}
              <div className={`space-y-3 pt-9 ${itemClass}`} style={itemDelay(120)}>
                <p className="max-w-[15rem] text-[15px] font-medium leading-[1.4] tracking-[-0.01em] text-foreground">
                  {config.tagline}
                </p>
                <Link
                  href={config.browseHref}
                  suppressHydrationWarning
                  className="group inline-flex items-center gap-1 text-[13px] font-medium text-brand transition-colors hover:text-foreground"
                >
                  {config.browseLabel}
                  <span aria-hidden="true" className="transition-transform duration-200 group-hover:translate-x-0.5">
                    →
                  </span>
                </Link>
              </div>

              {/* Market columns */}
              <div className="grid gap-x-8 gap-y-6 sm:grid-cols-2 lg:grid-cols-3">
                {config.columns.map((column, columnIndex) => (
                  <div key={column.title} className="space-y-1.5">
                    <div className={`flex items-baseline justify-between pb-0.5 ${itemClass}`} style={itemDelay(120)}>
                      <p className="text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">
                        {column.title}
                      </p>
                      <p className="text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">
                        {config.metricLabel}
                      </p>
                    </div>
                    <div className="space-y-0.5">
                      {column.rows.map((row, rowIndex) => (
                        <div
                          key={row.href}
                          className={itemClass}
                          style={itemDelay(155 + (rowIndex * numColumns + columnIndex) * 35)}
                        >
                          <Link
                            href={row.href}
                            suppressHydrationWarning
                            className="group -mx-2 flex items-center gap-2.5 rounded-lg px-2 py-1.5 transition-colors hover:bg-accent"
                          >
                            <span className="flex shrink-0 items-center">
                              <TokenIcon symbol={row.symbol} size="sm" />
                              {row.symbol2 ? <TokenIcon symbol={row.symbol2} size="sm" className="-ml-2" /> : null}
                            </span>
                            <span className="flex min-w-0 flex-1 items-baseline gap-1.5">
                              <span className="shrink-0 text-[13px] font-semibold text-foreground">
                                {row.label ?? row.symbol}
                              </span>
                              {row.name ? (
                                <span className="truncate text-[12px] text-muted-foreground">{row.name}</span>
                              ) : null}
                            </span>
                            <span
                              className={`w-14 shrink-0 text-right text-[13px] font-medium tabular-nums ${
                                row.metricTone === "negative"
                                  ? "text-rose-500"
                                  : row.metricTone === "positive"
                                    ? "text-emerald-500"
                                    : "text-foreground"
                              }`}
                            >
                              {row.metric}
                            </span>
                          </Link>
                        </div>
                      ))}
                    </div>
                    <div className={itemClass} style={itemDelay(155 + (3 * numColumns + columnIndex) * 35)}>
                      <Link
                        href={column.viewAllHref}
                        suppressHydrationWarning
                        className="group inline-flex items-center gap-1 px-2 text-[12px] font-medium text-muted-foreground transition-colors hover:text-foreground"
                      >
                        {t("View all")}
                        <span
                          aria-hidden="true"
                          className="transition-transform duration-200 group-hover:translate-x-0.5"
                        >
                          →
                        </span>
                      </Link>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
