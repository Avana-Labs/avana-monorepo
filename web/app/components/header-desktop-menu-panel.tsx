"use client"

import Link from "next/link"
import { useEffect, useRef, useState } from "react"
import { TokenIcon } from "@/app/components/token-icon"
import { OVERLAY_SCRIM_CLASS } from "@/app/components/card-surface-tokens"
import type { DesktopMenuId } from "@/app/components/header-desktop-menu-data"
import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend"
import { resolveLendMarketId } from "@/app/lib/lend-system/catalog"
import { BORROW_POOL_CATALOG, type BorrowPoolRow } from "@/app/lib/data/borrow-domain"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { MULTIPLY_MARKET_ROWS } from "@/app/lib/data/catalog/multiply"
import { categorizeMarket, type MarketCategory } from "@/app/lib/markets/category"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { buildSparklineLinePath, getSparklineColor } from "@/app/lib/sparkline"
import { createSeededRandom } from "@/app/lib/deterministic"

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

// Deep-link a column's "View all" to the product page with the matching category chip
// preselected (?category=). Stablecoins → forex, ETH family → eth, stocks/curated → smart.
function categoryHref(base: string, symbol: string): string {
  return `${base}?category=${categorizeMarket(symbol)}#markets`
}

// Niche stablecoins pushed below the majors so the Stablecoins column leads with USDC/USDT/GHO.
const LEND_DEMOTE = new Set(["EURC", "frxUSD"])

// Prefer a stablecoin / BTC / stocks spread so the columns span colours rather than reading as
// three near-identical blue columns.
function lendColumns(): PanelColumn[] {
  const preferred = ["Stablecoins", "Bitcoin Based", "Coinbase & Robinhood Stocks"]
  const byTitle = new Map(LEND_ASSET_GROUPS.map((group) => [group.title, group]))
  const chosen = preferred
    .map((title) => byTitle.get(title))
    .filter((group): group is (typeof LEND_ASSET_GROUPS)[number] => Boolean(group))
  for (const group of LEND_ASSET_GROUPS) {
    if (chosen.length >= 3) break
    if (!chosen.includes(group)) chosen.push(group)
  }
  return chosen.slice(0, 3).map((group) => {
    const rows = [...group.rows]
      .sort((a, b) => Number(LEND_DEMOTE.has(a.symbol)) - Number(LEND_DEMOTE.has(b.symbol)))
      .slice(0, 3)
    return {
      title: group.title === "Coinbase & Robinhood Stocks" ? "Stocks" : group.title,
      viewAllHref: categoryHref("/lend", rows[0]?.symbol ?? ""),
      rows: rows.map((row) => ({
        symbol: row.symbol,
        name: row.name,
        metric: `${row.apyValue.toFixed(2)}%`,
        metricTone: "positive" as const,
        href: `/lend/markets/${resolveLendMarketId(row.symbol)}`,
      })),
    }
  })
}

const CATEGORY_TITLE: Record<MarketCategory, string> = {
  eth: "ETH",
  btc: "BTC",
  forex: "Stablecoins",
  utility: "Utility",
  smart: "Smart",
}

// A pool's signature family for colour spread: its first non-stable leg, else stable.
function poolFamily(pool: BorrowPoolRow): MarketCategory {
  const cats = pool.visuals.map((visual) => categorizeMarket(visual.symbol))
  return cats.find((category) => category !== "forex") ?? "forex"
}

// Greedily pick up to `count` pools that maximise variety: each step takes the unused,
// unique-pair pool that introduces the most new tokens (tie-broken by a new token family), so a
// column doesn't lean on one token (e.g. USDC) in every row.
function pickDiversePools(pools: BorrowPoolRow[], count: number): BorrowPoolRow[] {
  const chosen: BorrowPoolRow[] = []
  const seenPairs = new Set<string>()
  const seenTokens = new Set<string>()
  const seenFamilies = new Set<MarketCategory>()
  const pairKey = (pool: BorrowPoolRow) =>
    [pool.visuals[0].symbol, pool.visuals[1].symbol]
      .map((symbol) => symbol.toUpperCase())
      .sort()
      .join("/")
  while (chosen.length < count) {
    let best: BorrowPoolRow | null = null
    let bestScore = -1
    for (const pool of pools) {
      if (seenPairs.has(pairKey(pool))) continue
      const newTokens = pool.visuals.filter((visual) => !seenTokens.has(visual.symbol.toUpperCase())).length
      const score = newTokens * 2 + (seenFamilies.has(poolFamily(pool)) ? 0 : 1)
      if (score > bestScore) {
        bestScore = score
        best = pool
      }
    }
    if (!best) break
    chosen.push(best)
    seenPairs.add(pairKey(best))
    seenFamilies.add(poolFamily(best))
    for (const visual of best.visuals) seenTokens.add(visual.symbol.toUpperCase())
  }
  return chosen
}

function poolDex(pool: BorrowPoolRow): string {
  const spoke = pool.spoke
  if (spoke.startsWith("uni")) return "Uniswap"
  if (spoke.startsWith("aero")) return "Aerodrome"
  if (spoke.startsWith("curve")) return "Curve"
  if (spoke.startsWith("bal")) return "Balancer"
  return pool.dexes[0]?.label ?? pool.venue
}

// Group collateral (LP) pools by venue (Uniswap / Aerodrome / Curve …); one column per DEX,
// deep-linking "View all" to the borrow page's search pre-filled with that venue.
function borrowColumns(): PanelColumn[] {
  const preferred = ["Uniswap", "Aerodrome", "Curve"]
  const byDex = new Map<string, BorrowPoolRow[]>()
  for (const pool of BORROW_POOL_CATALOG) {
    const dex = poolDex(pool)
    const bucket = byDex.get(dex) ?? []
    bucket.push(pool)
    byDex.set(dex, bucket)
  }
  const dexes = [
    ...preferred.filter((dex) => byDex.has(dex)),
    ...[...byDex.keys()].filter((dex) => !preferred.includes(dex)),
  ].slice(0, 3)
  return dexes.map((dex) => ({
    title: dex,
    viewAllHref: `/borrow?q=${encodeURIComponent(dex)}#markets`,
    rows: pickDiversePools(byDex.get(dex) ?? [], 3).map((pool) => ({
      symbol: pool.visuals[0].symbol,
      symbol2: pool.visuals[1].symbol,
      label: `${pool.visuals[0].symbol}/${pool.visuals[1].symbol}`,
      metric: `${((pool.aprMin + pool.aprMax) / 2).toFixed(1)}%`,
      // Deterministic recent-momentum tone so the APR colour matches its sparkline.
      metricTone: createSeededRandom(pool.id)() > 0.42 ? ("positive" as const) : ("negative" as const),
      href: borrowMarketDetailPath(pool.id),
    })),
  }))
}

// Group loop markets by their collateral's family; show a few of the populated buckets.
function multiplyColumns(): PanelColumn[] {
  const order: MarketCategory[] = ["eth", "btc", "forex", "utility", "smart"]
  const byCategory = new Map<MarketCategory, Array<(typeof MULTIPLY_MARKET_ROWS)[number]>>()
  for (const row of MULTIPLY_MARKET_ROWS) {
    const category = categorizeMarket(row.protocol)
    const bucket = byCategory.get(category) ?? []
    bucket.push(row)
    byCategory.set(category, bucket)
  }
  return order
    .filter((category) => (byCategory.get(category)?.length ?? 0) > 0)
    .slice(0, 3)
    .map((category) => ({
      title: CATEGORY_TITLE[category],
      viewAllHref: `/multiply?category=${category}#markets`,
      rows: (byCategory.get(category) ?? []).slice(0, 3).map((row) => ({
        symbol: row.protocol,
        symbol2: row.asset,
        label: `${row.protocol}/${row.asset}`,
        metric: row.apy,
        metricTone: row.apy.trim().startsWith("-") ? ("negative" as const) : ("positive" as const),
        href: row.href,
      })),
    }))
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
  if (menuId === "multiply") {
    return {
      tagline: t(
        "Supply collateral, borrow against it, resupply the borrowed capital, and repeat until your risk limit.",
      ),
      browseHref: "/multiply",
      browseLabel: t("Browse Multiply Page"),
      metricLabel: t("Net APY"),
      columns: multiplyColumns(),
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

// Small colour sparkline before the metric — the same deterministic mock the Featured cards use.
function RowSparkline({ seed, isPositive }: { seed: string; isPositive: boolean }) {
  const total = 40
  const random = createSeededRandom(seed)
  // Realistic mock series: a mean-reverting random walk plus a gentle up/down drift, then
  // min-max normalised so the line fills the box instead of saturating into a flat line.
  const series: number[] = []
  let level = 0
  for (let index = 0; index < total; index++) {
    level = level * 0.85 + (random() - 0.5) * 12
    const drift = (isPositive ? 1 : -1) * (index / (total - 1)) * 22
    series.push(drift + level + (random() - 0.5) * 6)
  }
  const min = Math.min(...series)
  const max = Math.max(...series)
  const range = Math.max(max - min, 0.0001)
  const points = series.map((value, index) => ({
    x: (index / (total - 1)) * 100,
    y: 88 - ((value - min) / range) * 76,
  }))
  const linePath = buildSparklineLinePath(points)
  const color = getSparklineColor(isPositive)
  return (
    <span aria-hidden="true" className="block h-6 w-16 shrink-0">
      <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="h-full w-full">
        <path
          d={linePath}
          fill="none"
          stroke={color}
          strokeWidth="1.25"
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
        />
      </svg>
    </span>
  )
}

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
                            <RowSparkline seed={row.href} isPositive={row.metricTone !== "negative"} />
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
