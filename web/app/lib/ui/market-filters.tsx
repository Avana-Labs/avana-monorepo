"use client"

import { lazy, Suspense, useMemo, useState, type Dispatch, type ReactNode, type SetStateAction } from "react"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"
import { MOBILE_EDGE_RAIL_CLASS } from "@/app/lib/ui/horizontal-rail"
import { TokenIcon } from "@/app/components/token-icon"
import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"
import { useHasMounted } from "@/app/lib/ui/use-has-mounted"
import { CloseIcon, FACET_TITLES, StaticFacetPill, type FacetPopoverProps } from "@/app/lib/ui/market-filter-pill"
import {
  ASSET_TABS,
  CHAIN_OPTIONS,
  EMPTY_MARKET_FILTERS,
  HUB_OPTIONS,
  activeFilterCount,
  facetCounts,
  type AssetOption,
  type AssetTabId,
  type FacetId,
  type FilterOption,
  type FilterableItem,
  type MarketFilterState,
} from "@/app/lib/markets/filters"

// ----- Icons (inline so they stay crisp at 16–18px and inherit currentColor) ------------------

function SearchIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={cn("size-[18px] shrink-0", className)}>
      <path d="m20 20-3.6-3.6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      <circle cx="10.75" cy="10.75" r="6.25" stroke="currentColor" strokeWidth="1.8" />
    </svg>
  )
}

function FilterLinesIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={cn("size-[18px] shrink-0", className)}>
      <path d="M4 7h16M7 12h10M10 17h4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  )
}

function ChevronsUpDownIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={cn("size-4 shrink-0", className)}>
      <path
        d="m8 9.5 4-4 4 4M8 14.5l4 4 4-4"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={cn("size-3.5", className)}>
      <path
        d="m5.5 12.5 4 4 9-9"
        stroke="currentColor"
        strokeWidth="2.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function OptionIcon({ option, size }: { option: FilterOption; size: number }) {
  if (!option.iconSrc) {
    return (
      <span
        aria-hidden="true"
        className="inline-flex shrink-0 items-center justify-center rounded-full bg-surface-inset text-[10px] font-semibold text-muted-foreground dark:bg-white/10"
        style={{ width: size, height: size }}
      >
        {option.label[0]}
      </span>
    )
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element -- tiny local icons, no layout shift at a fixed box
    <img
      src={sizedLocalIconSrc(option.iconSrc, size)}
      alt=""
      aria-hidden="true"
      width={size}
      height={size}
      className="shrink-0 rounded-full object-contain"
      style={{ width: size, height: size }}
    />
  )
}

/** 2×2 cluster of chain logos for the "All Chains" trigger, like a folder of apps. */
function ChainCluster({ chains }: { chains: ReadonlyArray<FilterOption> }) {
  const shown = chains.slice(0, 4)
  return (
    <span aria-hidden="true" className="grid size-5 shrink-0 grid-cols-2 gap-px">
      {shown.map((chain) => (
        <OptionIcon key={chain.id} option={chain} size={9} />
      ))}
    </span>
  )
}

// ----- Pieces --------------------------------------------------------------------------------

function useLabel() {
  const { t } = useTranslation()
  return (option: { label: string; brand?: boolean }) => (option.brand ? option.label : t(option.label))
}

function PanelSearch({
  value,
  onChange,
  placeholder,
  inputRef,
}: {
  value: string
  onChange: (value: string) => void
  placeholder: string
  inputRef: React.MutableRefObject<HTMLInputElement | null>
}) {
  const { t } = useTranslation()
  return (
    <label className="flex h-10 shrink-0 items-center gap-2 border-b border-border px-3 text-muted-foreground dark:border-white/[0.07]">
      <SearchIcon className="size-4 text-muted-foreground/80" />
      <input
        ref={inputRef}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        aria-label={placeholder}
        className="min-w-0 flex-1 bg-transparent text-[14px] text-foreground outline-none placeholder:text-muted-foreground/70 dark:text-white"
      />
      {value ? (
        <button
          type="button"
          aria-label={t("Clear search")}
          onClick={() => onChange("")}
          className="inline-flex size-5 items-center justify-center rounded-full text-muted-foreground hover:bg-hover hover:text-foreground"
        >
          <CloseIcon className="size-3.5" />
        </button>
      ) : null}
    </label>
  )
}

function SectionHeader({ label, canClear, onClear }: { label: string; canClear: boolean; onClear: () => void }) {
  const { t } = useTranslation()
  return (
    <div className="flex shrink-0 items-center justify-between px-3 pb-1 pt-2.5">
      <span className="text-[11px] font-medium uppercase tracking-[0.06em] text-muted-foreground">{label}</span>
      <button
        type="button"
        disabled={!canClear}
        onClick={onClear}
        className="text-[11px] font-medium uppercase tracking-[0.06em] text-foreground/80 transition-colors hover:text-foreground disabled:cursor-default disabled:text-muted-foreground/45 dark:text-white/80 dark:hover:text-white dark:disabled:text-white/25"
      >
        {t("Clear")}
      </button>
    </div>
  )
}

function OptionRow({
  checked,
  disabled,
  onToggle,
  leading,
  label,
  secondary,
  count,
  showCount = true,
  soon,
}: {
  checked: boolean
  disabled?: boolean
  onToggle: () => void
  leading?: ReactNode
  label: string
  secondary?: string
  count?: number
  /** Hide the number but keep dimming zero-match rows. */
  showCount?: boolean
  soon?: boolean
}) {
  const { t } = useTranslation()
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      aria-disabled={disabled || undefined}
      disabled={disabled}
      onClick={onToggle}
      className={cn(
        "flex min-h-9 w-full items-center gap-2.5 rounded-[9px] px-2 py-1.5 text-left outline-none transition-colors",
        "hover:bg-hover focus-visible:bg-hover disabled:cursor-default disabled:hover:bg-transparent",
      )}
    >
      <span
        aria-hidden="true"
        className={cn(
          "inline-flex size-[18px] shrink-0 items-center justify-center rounded-full border-[1.5px] transition-colors",
          checked
            ? "border-brand bg-brand text-white dark:text-[#0b0b0b]"
            : "border-foreground/20 text-transparent dark:border-white/20",
          disabled && "opacity-40",
        )}
      >
        <CheckIcon className="size-3" />
      </span>
      {leading ? <span className={cn("inline-flex", disabled && "opacity-40")}>{leading}</span> : null}
      <span
        className={cn(
          "flex min-w-0 flex-1 items-baseline gap-2",
          disabled ? "opacity-45" : count === 0 && !checked && "opacity-55",
        )}
      >
        <span
          className={cn(
            "truncate text-[14px]",
            checked ? "font-medium text-foreground dark:text-white" : "text-foreground/80 dark:text-white/80",
          )}
        >
          {label}
        </span>
        {secondary ? (
          <span className="shrink-0 text-[13px] text-muted-foreground dark:text-white/45">{secondary}</span>
        ) : null}
      </span>
      {soon ? (
        <span className="shrink-0 rounded-full bg-surface-inset px-1.5 py-px text-[10px] font-medium text-muted-foreground dark:bg-white/[0.06]">
          {t("Soon")}
        </span>
      ) : showCount && typeof count === "number" ? (
        <span className="shrink-0 text-[12px] tabular-nums text-muted-foreground/80 dark:text-white/35">{count}</span>
      ) : null}
    </button>
  )
}

function EmptyMatches() {
  const { t } = useTranslation()
  return <p className="px-3 py-4 text-center text-[13px] text-muted-foreground">{t("No matches")}</p>
}

// ----- Facet popover -------------------------------------------------------------------------

// Radix Popover is ~19 KiB gzip and nothing else on these pages uses it, so it loads after mount;
// the server and the first client render show the identical closed pill.
const LazyFacetPopover = lazy(() => import("@/app/lib/ui/market-filter-popover"))

function FacetPopover(props: FacetPopoverProps) {
  const mounted = useHasMounted()
  // A click on the stand-in pill while the chunk loads opens the panel once it arrives.
  const [openOnLoad, setOpenOnLoad] = useState(false)
  const pill = <StaticFacetPill {...props} onOpen={() => setOpenOnLoad(true)} />
  if (!mounted) return pill
  return (
    <Suspense fallback={pill}>
      <LazyFacetPopover {...props} initialOpen={openOnLoad} />
    </Suspense>
  )
}

function matchesQuery(query: string, ...values: string[]) {
  const needle = query.trim().toLowerCase()
  return needle.length === 0 || values.some((value) => value.toLowerCase().includes(needle))
}

function OptionListFacet({
  facet,
  heading,
  searchPlaceholder,
  options,
  selected,
  counts,
  onChange,
  trigger,
}: {
  facet: FacetId
  heading: string
  searchPlaceholder: string
  options: ReadonlyArray<FilterOption>
  selected: readonly string[]
  counts: Map<string, number>
  /** Functional update, so rapid toggles never read a stale selection. */
  onChange: (update: (current: readonly string[]) => string[]) => void
  trigger: (open: boolean) => ReactNode
}) {
  const label = useLabel()
  const [query, setQuery] = useState("")
  const visible = options.filter((option) => matchesQuery(query, label(option), option.label))
  // One logo column for the whole list, so a logo-less row (CoW Swap) still lines up.
  const withIcons = facet === "chains" || options.some((option) => option.iconSrc)
  const toggle = (id: string) =>
    onChange((current) => (current.includes(id) ? current.filter((value) => value !== id) : [...current, id]))

  return (
    <FacetPopover
      facet={facet}
      trigger={trigger}
      panelWidth={288}
      fitContent
      rowCount={options.length}
      selectedCount={selected.length}
      onClearFacet={() => onChange(() => [])}
    >
      {(inputRef) => (
        <>
          <PanelSearch value={query} onChange={setQuery} placeholder={searchPlaceholder} inputRef={inputRef} />
          <SectionHeader label={heading} canClear={selected.length > 0} onClear={() => onChange(() => [])} />
          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-1.5 pb-1.5" data-filter-options={facet}>
            {visible.length === 0 ? <EmptyMatches /> : null}
            {visible.map((option) => (
              <OptionRow
                key={option.id}
                checked={selected.includes(option.id)}
                disabled={option.soon}
                soon={option.soon}
                onToggle={() => toggle(option.id)}
                leading={withIcons ? <OptionIcon option={option} size={20} /> : undefined}
                label={label(option)}
                count={counts.get(option.id) ?? 0}
              />
            ))}
          </div>
        </>
      )}
    </FacetPopover>
  )
}

function AssetFacet({
  options,
  selected,
  counts,
  onChange,
  trigger,
}: {
  options: ReadonlyArray<AssetOption>
  selected: readonly string[]
  counts: Map<string, number>
  /** Functional update, so rapid toggles never read a stale selection. */
  onChange: (update: (current: readonly string[]) => string[]) => void
  trigger: (open: boolean) => ReactNode
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState("")
  const [tab, setTab] = useState<AssetTabId>("all")
  const tabs = ASSET_TABS.filter((entry) => entry.id === "all" || options.some((option) => option.tab === entry.id))
  const visible = options.filter(
    (option) => (tab === "all" || option.tab === tab) && matchesQuery(query, option.name, option.symbol),
  )
  const selectedKeys = new Set(selected.map((symbol) => symbol.toUpperCase()))
  // One market per asset (Lend) makes every count a "1": noise, so only show counts that vary.
  const showCounts = options.some((option) => (counts.get(option.symbol.toUpperCase()) ?? 0) > 1)
  const toggle = (symbol: string) => {
    const key = symbol.toUpperCase()
    onChange((current) =>
      current.some((value) => value.toUpperCase() === key)
        ? current.filter((value) => value.toUpperCase() !== key)
        : [...current, symbol],
    )
  }

  return (
    <FacetPopover
      facet="assets"
      trigger={trigger}
      panelWidth={324}
      rowCount={options.length + 1}
      selectedCount={selected.length}
      onClearFacet={() => onChange(() => [])}
    >
      {(inputRef) => (
        <>
          <PanelSearch value={query} onChange={setQuery} placeholder={t("Search assets")} inputRef={inputRef} />
          <div
            role="tablist"
            aria-label={t("Asset type")}
            className="flex shrink-0 items-end gap-3.5 overflow-x-auto border-b border-border px-3 [scrollbar-width:none] dark:border-white/[0.07] [&::-webkit-scrollbar]:hidden"
          >
            {tabs.map((entry) => {
              const active = entry.id === tab
              return (
                <button
                  key={entry.id}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  onClick={() => setTab(entry.id)}
                  className={cn(
                    "relative shrink-0 whitespace-nowrap pb-2 pt-2.5 text-[13px] transition-colors",
                    active
                      ? "font-medium text-foreground after:absolute after:inset-x-0 after:bottom-[-1px] after:h-[2px] after:rounded-full after:bg-foreground dark:text-white dark:after:bg-white"
                      : "text-muted-foreground hover:text-foreground dark:text-white/45 dark:hover:text-white/80",
                  )}
                >
                  {t(entry.label)}
                </button>
              )
            })}
          </div>
          <SectionHeader label={t("Assets")} canClear={selected.length > 0} onClear={() => onChange(() => [])} />
          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-1.5 pb-1.5" data-filter-options="assets">
            {visible.length === 0 ? <EmptyMatches /> : null}
            {visible.map((option) => (
              <OptionRow
                key={option.symbol}
                checked={selectedKeys.has(option.symbol.toUpperCase())}
                onToggle={() => toggle(option.symbol)}
                leading={<TokenIcon symbol={option.symbol} pixelSize={20} />}
                label={option.name}
                secondary={
                  option.name.toUpperCase() === option.symbol.toUpperCase()
                    ? undefined
                    : formatTokenDisplaySymbol(option.symbol)
                }
                count={counts.get(option.symbol.toUpperCase()) ?? 0}
                showCount={showCounts}
              />
            ))}
          </div>
        </>
      )}
    </FacetPopover>
  )
}

// ----- Bar -----------------------------------------------------------------------------------

function PageSearch({
  value,
  onChange,
  placeholder,
  className,
}: {
  value: string
  onChange: (value: string) => void
  placeholder: string
  className?: string
}) {
  const { t } = useTranslation()
  return (
    <label
      className={cn(
        "flex h-9 items-center gap-2.5 rounded-full border px-3.5 text-muted-foreground transition-colors",
        "border-border bg-card focus-within:border-foreground/25 dark:border-white/[0.07] dark:bg-transparent dark:focus-within:border-white/20",
        className,
      )}
    >
      <SearchIcon className="size-4 text-muted-foreground/80" />
      <input
        aria-label={placeholder}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        className="min-w-0 flex-1 bg-transparent text-[14px] text-foreground outline-none placeholder:text-muted-foreground/70 dark:text-white"
      />
      {value ? (
        <button
          type="button"
          aria-label={t("Clear search")}
          onClick={() => onChange("")}
          className="inline-flex size-6 shrink-0 items-center justify-center rounded-full hover:bg-hover hover:text-foreground"
        >
          <CloseIcon className="size-3.5" />
        </button>
      ) : null}
    </label>
  )
}

export type MarketFiltersBarProps = {
  /** Every row on the page, reduced to its facets (drives the per-option counts). */
  items: readonly FilterableItem[]
  value: MarketFilterState
  onChange: Dispatch<SetStateAction<MarketFilterState>>
  marketOptions: ReadonlyArray<FilterOption>
  assetOptions: ReadonlyArray<AssetOption>
  search: string
  onSearchChange: (value: string) => void
  searchPlaceholder: string
  className?: string
}

/**
 * Lend / Borrow / Multiply filter row: [All Chains] | [Hubs] [Markets] [Assets] … [search].
 * Each pill opens a searchable multi-select panel (portaled, so the horizontally scrolling
 * mobile rail can't clip it). A pill with a selection reads "Hubs (2)" and gains an ×.
 */
export function MarketFiltersBar({
  items,
  value,
  onChange,
  marketOptions,
  assetOptions,
  search,
  onSearchChange,
  searchPlaceholder,
  className,
}: MarketFiltersBarProps) {
  const { t } = useTranslation()
  const label = useLabel()
  const set = (facet: FacetId) => (update: (current: readonly string[]) => string[]) =>
    onChange((current) => ({ ...current, [facet]: update(current[facet]) }))

  const counts = useMemo(
    () => ({
      chains: facetCounts(items, value, "chains"),
      hubs: facetCounts(items, value, "hubs"),
      markets: facetCounts(items, value, "markets"),
      assets: facetCounts(items, value, "assets"),
    }),
    [items, value],
  )

  const selectedChains = CHAIN_OPTIONS.filter((chain) => value.chains.includes(chain.id))
  const pillLabel = (facet: Exclude<FacetId, "chains">) => {
    const count = value[facet].length
    return count > 0 ? `${t(FACET_TITLES[facet])} (${count})` : t(FACET_TITLES[facet])
  }
  const facetTrigger = (facet: Exclude<FacetId, "chains">) => () => (
    <>
      <FilterLinesIcon className="size-4 text-foreground/70 dark:text-white/70" />
      <span className="whitespace-nowrap">{pillLabel(facet)}</span>
    </>
  )

  const chainTrigger = () => (
    <>
      {selectedChains.length === 1 ? (
        <OptionIcon option={selectedChains[0]} size={20} />
      ) : (
        <ChainCluster chains={selectedChains.length > 1 ? selectedChains : CHAIN_OPTIONS} />
      )}
      <span className="whitespace-nowrap">
        {selectedChains.length === 0
          ? t("All Chains")
          : selectedChains.length === 1
            ? label(selectedChains[0])
            : `${t("Chains")} (${selectedChains.length})`}
      </span>
      <ChevronsUpDownIcon className="size-3.5 text-foreground/60 dark:text-white/60" />
    </>
  )

  const anyActive = activeFilterCount(value) > 0

  const pills = (
    <>
      <OptionListFacet
        facet="chains"
        heading={t("Filter by")}
        searchPlaceholder={t("Search chains")}
        options={CHAIN_OPTIONS}
        selected={value.chains}
        counts={counts.chains}
        onChange={set("chains")}
        trigger={chainTrigger}
      />
      <span aria-hidden="true" className="h-5 w-px shrink-0 bg-border dark:bg-white/10" />
      <OptionListFacet
        facet="hubs"
        heading={t("Hubs")}
        searchPlaceholder={t("Search hubs")}
        options={HUB_OPTIONS}
        selected={value.hubs}
        counts={counts.hubs}
        onChange={set("hubs")}
        trigger={facetTrigger("hubs")}
      />
      <OptionListFacet
        facet="markets"
        heading={t("Markets")}
        searchPlaceholder={t("Search markets")}
        options={marketOptions}
        selected={value.markets}
        counts={counts.markets}
        onChange={set("markets")}
        trigger={facetTrigger("markets")}
      />
      <AssetFacet
        options={assetOptions}
        selected={value.assets}
        counts={counts.assets}
        onChange={set("assets")}
        trigger={facetTrigger("assets")}
      />
      {anyActive ? (
        <button
          type="button"
          onClick={() => onChange(EMPTY_MARKET_FILTERS)}
          className="ml-1 shrink-0 whitespace-nowrap rounded-full px-2 py-1 text-[14px] font-medium text-muted-foreground transition-colors hover:text-foreground dark:hover:text-white"
        >
          {t("Clear all")}
        </button>
      ) : null}
    </>
  )

  return (
    // One render for every width: phones and tablets stack a full-width search over a
    // horizontally scrolling rail of pills; lg+ puts the pills left and the search right.
    <div
      className={cn("flex w-full flex-col gap-3 lg:flex-row lg:items-center", className)}
      data-testid="market-filters"
    >
      <div
        className={cn(
          "flex min-w-0 flex-1 items-center gap-2 overflow-x-auto pb-1 [scrollbar-width:none] md:gap-2.5 lg:flex-wrap lg:overflow-visible lg:pb-0 [&::-webkit-scrollbar]:hidden",
          MOBILE_EDGE_RAIL_CLASS,
        )}
        data-testid="market-filters-rail"
      >
        {pills}
      </div>
      <PageSearch
        value={search}
        onChange={onSearchChange}
        placeholder={searchPlaceholder}
        className="order-first w-full lg:order-none lg:w-[260px] lg:shrink-0 xl:w-[300px]"
      />
    </div>
  )
}

/** Empty result for a filtered market list, with a one-click reset of every filter and the search. */
export function MarketFiltersEmptyState({ message, onClear }: { message: string; onClear?: () => void }) {
  const { t } = useTranslation()
  return (
    <div className="flex flex-col items-center gap-3 rounded-radius-md bg-card px-6 py-10 text-center text-[14px] text-muted-foreground">
      <p>{message}</p>
      {onClear ? (
        <button
          type="button"
          onClick={onClear}
          className="rounded-full border border-border px-4 py-1.5 text-[14px] font-medium text-foreground transition-colors hover:bg-surface-hover dark:border-white/10 dark:text-white dark:hover:bg-white/[0.06]"
        >
          {t("Clear filters")}
        </button>
      ) : null}
    </div>
  )
}
