"use client"

import { usePathname, useRouter, useSearchParams } from "next/navigation"
import { Sparkles } from "@/app/components/icons"
import { triggerPageLoading } from "@/app/lib/page-loading"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { askAIHref } from "@/app/lib/ask-ai/navigation"

// The "Ask AI" entry point. Two shapes:
//   • text chip (default) — a filled inner pill that nests on the RIGHT of the
//     header search bar, YouTube-style. SearchTrigger renders it inside the pill.
//   • iconOnly — a bare sparkle button used standalone in the phone / small-desktop
//     headers, beside the search icon.
export function AskAssistantTrigger({
  iconOnly = false,
  // "nav" matches the muted desktop chrome; "brand" is the phone-only cyan that
  // mirrors the adjacent search icon. Only applies to the iconOnly shape.
  tone = "nav",
  onClick,
}: {
  iconOnly?: boolean
  tone?: "nav" | "brand"
  onClick?: () => void
}) {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()
  const { t } = useTranslation()

  const handleClick = () => {
    if (onClick) {
      onClick()
      return
    }
    const query = searchParams.toString()
    const returnHref = `${pathname}${query ? `?${query}` : ""}`
    try {
      sessionStorage.setItem("avana:ask-ai-opened-from", returnHref)
    } catch {
      // private mode / blocked storage — close still falls back to router.push
    }
    triggerPageLoading()
    router.push(askAIHref(returnHref))
  }

  return (
    <button
      type="button"
      aria-label={t("Ask AI")}
      title={t("Ask AI")}
      onClick={handleClick}
      className={
        iconOnly
          ? tone === "brand"
            ? "inline-flex h-10 w-10 items-center justify-center text-[#01AACF] transition hover:text-[#01AACF]/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 [-webkit-tap-highlight-color:transparent]"
            : "inline-flex h-10 w-10 items-center justify-center text-muted-foreground transition-colors hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 dark:hover:text-[#7DDCFF] [-webkit-tap-highlight-color:transparent]"
          : "flex h-7 shrink-0 items-center gap-1.5 rounded-full bg-[#ececec] px-3 text-[13px] font-normal text-foreground transition-colors hover:bg-[#e3e3e3] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background lg:h-8 lg:gap-2 lg:px-3.5 lg:text-[14px] dark:bg-surface-hover dark:hover:bg-[hsl(0_0%_21%)]"
      }
    >
      {iconOnly ? (
        <Sparkles className="h-5 w-5" />
      ) : (
        <>
          <Sparkles className="h-4 w-4 shrink-0 text-foreground lg:h-[17px] lg:w-[17px]" />
          <span className="whitespace-nowrap">{t("Ask AI")}</span>
        </>
      )}
    </button>
  )
}
