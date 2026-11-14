"use client"

import { useHydrated } from "@/app/lib/siwe/use-siwe-auth"
import { AskAssistantTrigger } from "./ask-assistant-trigger"
import { Search } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"

// The single source of truth for the header search trigger's markup. Both the
// real SearchCommand and the pre-hydration placeholder (search-command is a
// `ssr: false` dynamic import) render this, so the swap from placeholder to the
// hydrated component is visually seamless — no color/text flash on load.
//
// The full (non-iconOnly) shape is a pill that nests the "Ask AI" chip on its
// right edge, YouTube-style. It is therefore a <div> with two sibling buttons —
// the search area (opens the command dialog) and the Ask AI chip — since a
// <button> can't legally contain another <button>.
export function SearchTrigger({
  iconOnly = false,
  // "nav" matches Dashboard / Umbrella muted chrome; "brand" is the phone-only cyan.
  tone = "nav",
  onClick,
  onAskClick,
  onIntent,
}: {
  iconOnly?: boolean
  tone?: "nav" | "brand"
  onClick?: () => void
  onAskClick?: () => void
  onIntent?: () => void
}) {
  const { t } = useTranslation()
  const hydrated = useHydrated()

  if (iconOnly) {
    return (
      <button
        type="button"
        aria-label={t("Search Avana")}
        disabled={!hydrated}
        onClick={onClick}
        onPointerEnter={onIntent}
        onFocus={onIntent}
        onTouchStart={onIntent}
        className={
          tone === "brand"
            ? "inline-flex h-10 w-10 items-center justify-center text-[#01AACF] transition hover:text-[#01AACF]/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 [-webkit-tap-highlight-color:transparent]"
            : "inline-flex h-10 w-10 items-center justify-center text-muted-foreground transition-colors hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 dark:hover:text-[#7DDCFF] [-webkit-tap-highlight-color:transparent]"
        }
      >
        <Search className="h-5 w-5" />
      </button>
    )
  }

  // Desktop press bounce, matching the home action cards (`SwapStyleField`): shrink while the
  // search area is held, then spring back past 1 on release. Pressing the nested Ask AI chip
  // does not bounce the whole pill.
  return (
    <div
      className="flex h-9 w-full origin-center items-center rounded-full border border-[#e6e6e6] bg-[#fafafa] pe-1 ps-3.5 shadow-none lg:h-10 lg:pe-1 lg:ps-4 lg:transition-transform lg:duration-200 lg:motion-safe:[&:has([data-search-area]:active)]:scale-[0.96] dark:border-border/60 dark:bg-surface-2"
      style={{ transitionTimingFunction: "cubic-bezier(0.34, 1.56, 0.64, 1)" }}
    >
      <button
        type="button"
        data-search-area=""
        aria-label={t("Search Avana")}
        disabled={!hydrated}
        onClick={onClick}
        onPointerEnter={onIntent}
        onFocus={onIntent}
        onTouchStart={onIntent}
        className="flex h-full min-w-0 flex-1 items-center gap-2.5 bg-transparent text-left text-[14px] font-normal tracking-[-0.01em] text-[#767676] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background lg:gap-3 lg:text-[15px] dark:text-muted-foreground"
      >
        <Search className="h-4 w-4 shrink-0 text-[#8a8a8a] dark:text-muted-foreground/80 lg:h-[17px] lg:w-[17px]" />
        <span className="min-w-0 flex-1 truncate">{t("Search Avana")}</span>
      </button>
      <AskAssistantTrigger onClick={onAskClick} />
    </div>
  )
}
