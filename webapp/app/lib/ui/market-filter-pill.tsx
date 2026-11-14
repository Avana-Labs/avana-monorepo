"use client"

import type { MutableRefObject, ReactNode } from "react"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { FacetId } from "@/app/lib/markets/filters"

// Pill pieces shared by the lazy Radix popover (`market-filter-popover.tsx`) and the static pill
// that stands in for it until that chunk loads. Keep this file free of Radix.

export function CloseIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={cn("size-4 shrink-0", className)}>
      <path d="M7 7l10 10M17 7 7 17" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  )
}

export const PILL_BASE =
  "group/pill inline-flex h-9 shrink-0 items-center rounded-full border text-[14px] font-medium tracking-[-0.01em] transition-colors " +
  "border-border bg-card text-foreground hover:bg-surface-hover " +
  "dark:border-white/[0.07] dark:bg-[#1c1c1c] dark:text-white dark:hover:bg-[#232323]"

export const PILL_OPEN = "bg-surface-hover dark:bg-[#252525] dark:border-white/[0.12]"

export const FACET_TITLES: Record<FacetId, string> = {
  chains: "Chains",
  hubs: "Hubs",
  markets: "Markets",
  assets: "Assets",
}

/** Chains never shows the pill's ×; the other facets do once something is selected. */
export function showsClear(facet: FacetId, selectedCount: number) {
  return selectedCount > 0 && facet !== "chains"
}

export function pillTriggerClass(facet: FacetId, selectedCount: number) {
  return cn(
    "inline-flex h-full items-center gap-2 rounded-full pl-3.5 outline-none focus-visible:ring-2 focus-visible:ring-ring",
    showsClear(facet, selectedCount) ? "pr-1" : "pr-3.5",
  )
}

export function useClearFacetLabel(facet: FacetId) {
  const { t } = useTranslation()
  return t("Clear {facet} filter").replace("{facet}", t(FACET_TITLES[facet]))
}

export function PillClearButton({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className="mr-1.5 inline-flex size-6 items-center justify-center rounded-full text-foreground/70 transition-colors hover:bg-hover hover:text-foreground dark:text-white/70 dark:hover:text-white"
    >
      <CloseIcon />
    </button>
  )
}

export type FacetPopoverProps = {
  facet: FacetId
  trigger: (open: boolean) => ReactNode
  panelWidth: number
  /** Shrink to the widest option (short lists like Chains/Hubs) instead of a fixed width. */
  fitContent?: boolean
  /** Option rows plus any tab strip, to size the room the panel needs below its pill. */
  rowCount: number
  onClearFacet: () => void
  selectedCount: number
  children: (inputRef: MutableRefObject<HTMLInputElement | null>) => ReactNode
  /** Mount already open: the pill was clicked before the popover chunk finished loading. */
  initialOpen?: boolean
}

/** The closed pill with the Radix one's markup, rendered on the server and until that chunk loads. */
export function StaticFacetPill({
  facet,
  trigger,
  selectedCount,
  onClearFacet,
  onOpen,
}: FacetPopoverProps & { onOpen: () => void }) {
  const clearLabel = useClearFacetLabel(facet)
  return (
    <span className={PILL_BASE} data-facet={facet} data-state="closed" data-pill="static">
      <button
        type="button"
        aria-haspopup="dialog"
        aria-expanded={false}
        data-state="closed"
        onClick={onOpen}
        className={pillTriggerClass(facet, selectedCount)}
      >
        {trigger(false)}
      </button>
      {showsClear(facet, selectedCount) ? <PillClearButton label={clearLabel} onClick={onClearFacet} /> : null}
    </span>
  )
}
