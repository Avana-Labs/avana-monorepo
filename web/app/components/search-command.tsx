"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import { ArrowUpRight, BadgeDollarSign, Layers3, Search, Sparkles } from "@/app/components/icons"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { SearchTrigger } from "./search-trigger"
import { triggerPageLoading } from "@/app/lib/page-loading"
import { borrowAssetDetailPath } from "@/app/lib/borrow-routes"
import { resolveLendMarketId } from "@/app/lib/lend-system/catalog"
import type { BorrowAssetVisual } from "@/app/lib/borrow-sim"
import { formatBorrowPairLabel, formatLtvPct } from "@/app/lib/borrow-sim"
import { TOKEN_ICON_TABLE_PX } from "@/app/lib/token-icon-sizes"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { rankResults } from "@/app/lib/search-ranking"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useBorrowSessionContextOptional } from "@/app/lib/avana-session/avana-sessions-context"
import type { BorrowPoolRow, BorrowableAsset } from "@/app/lib/borrow-sim"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type SearchTab = "all" | "pools" | "borrow" | "lend"

type SearchResult = {
  id: string
  tab: Exclude<SearchTab, "all">
  title: string
  subtitle: string
  eyebrow: string
  metric: string
  href: string
  keywords: string
  visual: BorrowAssetVisual | [BorrowAssetVisual, BorrowAssetVisual]
}

const TABS: Array<{ id: SearchTab; label: string }> = [
  { id: "all", label: "All" },
  { id: "pools", label: "Collateral pools" },
  { id: "borrow", label: "Borrow" },
  { id: "lend", label: "Lend" },
]

function SearchResultImage({ src }: { src: string }) {
  return (
    // Results stay usable even while icons are loading on a slow connection.
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={sizedLocalIconSrc(src, 32)}
      alt=""
      width={TOKEN_ICON_TABLE_PX}
      height={TOKEN_ICON_TABLE_PX}
      loading="lazy"
      decoding="async"
      className="size-full object-contain"
    />
  )
}

async function getSearchResults(
  formatCompactCurrency: (usd: number) => string,
  t: (key: string) => string,
  hydratedPools: BorrowPoolRow[],
  hydratedAssets: BorrowableAsset[],
): Promise<SearchResult[]> {
  // Read pool + borrowable numbers from the Convex-hydrated session state (fed by
  // listBorrowMarketSnapshots) so the search box shows the SAME TVL/available/APR
  // the borrow list + detail show. Lend symbol set stays catalog-derived — it's a
  // set membership filter, not a number.
  const { MARKETS, TOKENS } = await import("@/app/lend/components/data")
  const lendSymbols: ReadonlySet<string> = new Set([
    ...TOKENS.map((token) => token.symbol),
    ...MARKETS.map((market) => market.symbol),
  ])
  const poolResults = hydratedPools.slice(0, 18).map((pool) => ({
    id: `pool-${pool.id}`,
    tab: "pools" as const,
    title: formatBorrowPairLabel(pool),
    // Label the pool's swap fee TIER explicitly ("0.30% pool fee") so it reads
    // distinctly from the annualized borrow "Fees" APR shown on borrow tables / Explore.
    subtitle: `${pool.venue} / ${pool.feeTier} ${t("pool fee")} / ${formatCompactCurrency(pool.availableUsd)} ${t("available")}`,
    eyebrow: "Collateral pool",
    metric: `${formatLtvPct(pool.ltv)} LTV`,
    href: `/borrow/markets/${pool.id}`,
    keywords: `${pool.name} ${pool.venue} ${pool.spoke} collateral lp pool liquidity ${pool.borrowableTokens
      .map((token) => token.symbol)
      .join(" ")}`,
    visual: pool.visuals,
  }))

  const borrowResults = hydratedAssets.map((asset) => ({
    id: `borrow-${asset.id}`,
    tab: "borrow" as const,
    title: asset.name,
    subtitle: `${asset.symbol} / ${asset.subtitle} / ${formatCompactCurrency(asset.availableUsd)} ${t("available")}`,
    eyebrow: "Borrow asset",
    metric: `${asset.borrowApr.toFixed(1)}% APR`,
    href: borrowAssetDetailPath(asset.id),
    keywords: `${asset.id} ${asset.symbol} ${asset.name} borrow debt credit asset`,
    visual: asset.visual,
  }))

  const lendResults = hydratedAssets
    .filter((asset) => lendSymbols.has(asset.symbol))
    .slice(0, 12)
    .map((asset) => ({
      id: `lend-${asset.id}`,
      tab: "lend" as const,
      title: asset.name,
      subtitle: `${asset.symbol} ${t("lending market")} / ${asset.utilization}% ${t("utilization")}`,
      eyebrow: "Lend asset",
      metric: `${Math.max(asset.borrowApr - 0.8, 0.1).toFixed(1)}% APY`,
      // Lend results are presented as lend markets — link into the lend product, not
      // the borrow asset page. Same slug derivation the lend list/detail use.
      href: `/lend/markets/${resolveLendMarketId(asset.symbol)}`,
      keywords: `${asset.id} ${asset.symbol} ${asset.name} lend deposit supply yield apy`,
      visual: asset.visual,
    }))

  return [...poolResults, ...borrowResults, ...lendResults]
}

function TokenAvatar({ visual }: { visual: BorrowAssetVisual }) {
  return (
    <span
      className={cn(
        "flex size-8 shrink-0 items-center justify-center text-[10px] font-medium",
        visual.iconUrl ? undefined : cn("overflow-hidden rounded-full", visual.bgClass, visual.textClass),
      )}
    >
      {visual.iconUrl ? <SearchResultImage src={visual.iconUrl} /> : visual.shortLabel}
    </span>
  )
}

function PoolAvatar({ visuals }: { visuals: [BorrowAssetVisual, BorrowAssetVisual] }) {
  return (
    <span className="relative flex h-9 w-11 shrink-0 items-center">
      <span
        className={cn(
          "absolute left-0 flex size-8 items-center justify-center",
          visuals[0].iconUrl
            ? undefined
            : cn("overflow-hidden rounded-full ring-2 ring-background", visuals[0].bgClass, visuals[0].textClass),
        )}
      >
        {visuals[0].iconUrl ? (
          <SearchResultImage src={visuals[0].iconUrl} />
        ) : (
          <span className="text-[9px] font-medium">{visuals[0].shortLabel}</span>
        )}
      </span>
      <span
        className={cn(
          "absolute left-5 flex size-8 items-center justify-center",
          visuals[1].iconUrl
            ? undefined
            : cn("overflow-hidden rounded-full ring-2 ring-background", visuals[1].bgClass, visuals[1].textClass),
        )}
      >
        {visuals[1].iconUrl ? (
          <SearchResultImage src={visuals[1].iconUrl} />
        ) : (
          <span className="text-[9px] font-medium">{visuals[1].shortLabel}</span>
        )}
      </span>
    </span>
  )
}

function ResultIcon({ result }: { result: SearchResult }) {
  if (Array.isArray(result.visual)) {
    return <PoolAvatar visuals={result.visual} />
  }

  return <TokenAvatar visual={result.visual} />
}

function SectionIcon({ tab }: { tab: SearchResult["tab"] }) {
  if (tab === "pools") return <Layers3 className="h-3.5 w-3.5" />
  if (tab === "borrow") return <BadgeDollarSign className="h-3.5 w-3.5" />
  return <Sparkles className="h-3.5 w-3.5" />
}

function isTypingTarget(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false
  const tagName = target.tagName
  return target.isContentEditable || tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT"
}

// Every breakpoint renders its own <SearchCommand /> (desktop pill, compact icon,
// phone icon) and all of them stay mounted at once — only CSS hides the inactive
// ones. A per-instance "/" listener therefore opened one dialog PER mounted
// instance, stacking 2–3 portaled overlays that each needed a separate click to
// dismiss. Share ONE global "/" handler across instances so a single dialog opens.
const slashShortcutOpeners = new Set<() => void>()
let slashShortcutListening = false

function handleSlashShortcut(event: KeyboardEvent) {
  if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey || isTypingTarget(event.target)) {
    return
  }
  const open = slashShortcutOpeners.values().next().value
  if (!open) return
  event.preventDefault()
  open()
}

function registerSlashShortcut(open: () => void) {
  slashShortcutOpeners.add(open)
  if (!slashShortcutListening && typeof window !== "undefined") {
    window.addEventListener("keydown", handleSlashShortcut)
    slashShortcutListening = true
  }
  return () => {
    slashShortcutOpeners.delete(open)
    if (slashShortcutOpeners.size === 0 && slashShortcutListening && typeof window !== "undefined") {
      window.removeEventListener("keydown", handleSlashShortcut)
      slashShortcutListening = false
    }
  }
}

export function SearchCommand({
  iconOnly = false,
  tone = "nav",
  initialOpen = false,
}: { iconOnly?: boolean; tone?: "nav" | "brand"; initialOpen?: boolean } = {}) {
  const router = useRouter()
  const { t } = useTranslation()
  const { compact } = useCurrency()
  const borrowSession = useBorrowSessionContextOptional()
  const [open, setOpen] = useState(initialOpen)
  const [query, setQuery] = useState("")
  const [activeTab, setActiveTab] = useState<SearchTab>("all")
  const [results, setResults] = useState<SearchResult[] | null>(null)
  const [loadingResults, setLoadingResults] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)
  const activeItemRef = useRef<HTMLButtonElement | null>(null)

  const loadResults = useCallback(async () => {
    if (results || loadingResults) {
      return
    }

    setLoadingResults(true)

    try {
      // Prefer the Convex-hydrated session state (matches list/detail numbers). If the
      // search command is mounted outside AvanaSessionsProvider (e.g. an isolated test
      // wrapper), fall back to the static catalog so the box still renders.
      let hydratedPools: BorrowPoolRow[] = borrowSession?.marketSummaries ?? []
      let hydratedAssets: BorrowableAsset[] = borrowSession?.borrowableAssets ?? []
      if (hydratedPools.length === 0 || hydratedAssets.length === 0) {
        const { BORROW_POOL_CATALOG, BORROWABLE_ASSETS } = await import("@/app/lib/borrow-sim")
        if (hydratedPools.length === 0) hydratedPools = BORROW_POOL_CATALOG
        if (hydratedAssets.length === 0) hydratedAssets = BORROWABLE_ASSETS
      }
      const nextResults = await getSearchResults(compact, t, hydratedPools, hydratedAssets)
      setResults(nextResults)
    } finally {
      setLoadingResults(false)
    }
  }, [borrowSession, compact, loadingResults, results, t])

  useEffect(() => {
    setResults(null)
  }, [compact])

  useEffect(() => {
    return registerSlashShortcut(() => {
      void loadResults()
      setOpen(true)
    })
  }, [loadResults])

  useEffect(() => {
    if (!open) {
      return
    }

    void loadResults()
  }, [loadResults, open])

  const normalizedQuery = query.trim().toLowerCase()
  const resolvedResults = results ?? []
  const resultsPending = results === null

  const groupedResults = useMemo<Array<[SearchResult["tab"], SearchResult[]]>>(() => {
    const tabScoped = resolvedResults.filter((result) => activeTab === "all" || result.tab === activeTab)
    const ranked = rankResults(tabScoped, normalizedQuery)
    const groupLimit = activeTab === "all" && !normalizedQuery ? 4 : 12
    return (["pools", "borrow", "lend"] as const)
      .map(
        (tab) =>
          [tab, ranked.filter((result) => result.tab === tab).slice(0, groupLimit)] as [
            SearchResult["tab"],
            SearchResult[],
          ],
      )
      .filter(([, group]) => group.length > 0)
  }, [resolvedResults, activeTab, normalizedQuery])

  // Flat list in rendered order, used for keyboard navigation.
  const flatResults = useMemo(() => {
    const next: SearchResult[] = []
    for (const [, group] of groupedResults) {
      next.push(...group)
    }
    return next
  }, [groupedResults])

  // Reset/clamp the active item whenever the visible list changes.
  useEffect(() => {
    setActiveIndex((current) => (flatResults.length === 0 ? 0 : Math.min(current, flatResults.length - 1)))
  }, [flatResults])

  useEffect(() => {
    setActiveIndex(0)
  }, [normalizedQuery, activeTab])

  useEffect(() => {
    activeItemRef.current?.scrollIntoView?.({ block: "nearest" })
  }, [activeIndex])

  const goToResult = (href: string) => {
    setOpen(false)
    setQuery("")
    setActiveIndex(0)
    triggerPageLoading()
    router.push(href)
  }

  const handleInputKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      // Close on a single Escape even when a query is present. Without this the
      // keystroke can be consumed clearing the input first, needing a second press.
      event.preventDefault()
      event.stopPropagation()
      setOpen(false)
      setQuery("")
      setActiveIndex(0)
      return
    }
    if (flatResults.length === 0) return
    if (event.key === "ArrowDown") {
      event.preventDefault()
      setActiveIndex((current) => (current + 1) % flatResults.length)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      setActiveIndex((current) => (current - 1 + flatResults.length) % flatResults.length)
    } else if (event.key === "Enter") {
      const active = flatResults[activeIndex]
      if (active) {
        event.preventDefault()
        goToResult(active.href)
      }
    }
  }

  return (
    <>
      <SearchTrigger
        iconOnly={iconOnly}
        tone={tone}
        onClick={() => {
          void loadResults()
          setOpen(true)
        }}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[min(620px,calc(100dvh-96px))] w-full max-w-[600px] gap-0 overflow-hidden rounded-radius-xl border-border bg-background p-0 shadow-[0_24px_80px_rgba(15,23,42,0.22)] sm:w-[calc(100vw-24px)] sm:rounded-radius-xl [&>button]:right-3.5 [&>button]:top-3.5 [&>button]:rounded-full">
          <DialogTitle className="sr-only">{t("Search Avana")}</DialogTitle>
          <DialogDescription className="sr-only">
            {t("Search collateral pools, assets to borrow, and assets to lend.")}
          </DialogDescription>

          <div className="flex items-center gap-3 border-b border-border px-4 py-3">
            <Search className="h-[18px] w-[18px] shrink-0 text-muted-foreground" />
            <input
              autoFocus
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={handleInputKeyDown}
              role="combobox"
              aria-expanded={flatResults.length > 0}
              aria-controls="search-command-results"
              aria-activedescendant={
                flatResults[activeIndex] ? `search-result-${flatResults[activeIndex].id}` : undefined
              }
              placeholder={t("Search Avana")}
              className="h-8 min-w-0 flex-1 bg-transparent text-[16px] font-normal text-foreground outline-none placeholder:text-muted-foreground"
            />
          </div>

          <div className="flex gap-1 border-b border-border px-3 py-2">
            {TABS.map((tab) => {
              const isActive = tab.id === activeTab
              return (
                <button
                  key={tab.id}
                  type="button"
                  onClick={() => setActiveTab(tab.id)}
                  className={cn(
                    "rounded-full px-2.5 py-1.5 text-[13px] font-medium transition-colors",
                    isActive ? "bg-surface-inset text-foreground" : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  {t(tab.label)}
                </button>
              )
            })}
          </div>

          <div
            id="search-command-results"
            role="listbox"
            className="min-h-[430px] max-h-[430px] overflow-y-auto px-2 py-2.5"
          >
            {resultsPending ? (
              <div className="flex min-h-[400px] items-center justify-center px-5 py-12 text-center">
                <div>
                  <p className="text-[15px] font-medium text-foreground">{t("Loading results")}</p>
                  <p className="mt-1 text-[13px] text-muted-foreground">
                    {t("Preparing pools, borrow assets, and lend assets.")}
                  </p>
                </div>
              </div>
            ) : groupedResults.length > 0 ? (
              groupedResults.map(([tab, group]) => (
                <section key={tab} className="pb-3.5">
                  <div className="flex items-center gap-2 px-3 pb-1.5 pt-2 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                    <SectionIcon tab={tab} />
                    <span>
                      {t(
                        tab === "pools"
                          ? "Pools to use as collateral"
                          : tab === "borrow"
                            ? "Assets to borrow"
                            : "Assets to lend",
                      )}
                    </span>
                    <span className="ml-auto rounded-full bg-surface-inset px-1.5 py-0.5 text-[10px] font-medium tabular-nums text-muted-foreground/80">
                      {group.length}
                    </span>
                  </div>
                  <div className="space-y-0.5">
                    {group.map((result) => {
                      const flatIndex = flatResults.indexOf(result)
                      const isActive = flatIndex === activeIndex
                      return (
                        <button
                          key={result.id}
                          id={`search-result-${result.id}`}
                          ref={isActive ? activeItemRef : undefined}
                          role="option"
                          aria-selected={isActive}
                          type="button"
                          onClick={() => goToResult(result.href)}
                          onMouseMove={() => setActiveIndex(flatIndex)}
                          className={cn(
                            "group flex w-full items-center gap-3 rounded-radius-md px-3 py-2 text-left transition-colors hover:bg-hover",
                            isActive && "bg-surface-inset",
                          )}
                        >
                          <ResultIcon result={result} />
                          <span className="min-w-0 flex-1">
                            <span className="flex items-center gap-2">
                              <span className="truncate text-[14px] font-medium leading-5 text-foreground">
                                {result.title}
                              </span>
                              <span className="hidden shrink-0 rounded-full bg-surface-inset px-2 py-0.5 text-[10px] font-medium text-muted-foreground sm:inline-flex">
                                {t(result.eyebrow)}
                              </span>
                            </span>
                            <span className="block truncate text-[12px] leading-5 text-muted-foreground">
                              {result.subtitle}
                            </span>
                          </span>
                          <span className="flex shrink-0 items-center gap-1.5 text-[12px] font-medium text-muted-foreground group-hover:text-foreground">
                            {result.metric}
                            <ArrowUpRight className="h-3.5 w-3.5 opacity-0 transition-opacity group-hover:opacity-100" />
                          </span>
                        </button>
                      )
                    })}
                  </div>
                </section>
              ))
            ) : (
              <div className="px-5 py-12 text-center">
                <p className="text-[15px] font-medium text-foreground">{t("No results found")}</p>
                <p className="mt-1 text-[13px] text-muted-foreground">
                  {t("Try a token symbol, pool pair, or action like borrow.")}
                </p>
              </div>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
