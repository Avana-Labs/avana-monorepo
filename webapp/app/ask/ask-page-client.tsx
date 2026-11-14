"use client"

import Link from "next/link"
import { useSpeculativeLoading } from "@/app/lib/performance/speculative-loading"
import dynamic from "next/dynamic"
import { useCallback, useEffect, useState } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import { BrandIcon, BrandLogo } from "@/app/components/brand-logo"
import { X } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { resolveAskAICloseHref } from "@/app/lib/ask-ai/navigation"
import { useHydrated } from "@/app/lib/siwe/use-siwe-auth"
import { AskAIHeaderTitleSkeleton, AskAILoadingBody } from "./components/ask-ai-skeleton"
import { AskAIConvexBoundary } from "./ask-ai-convex-boundary"

const loadAskAIPage = () => import("./ask-ai-page-client").then((mod) => mod.AskAIPageClient)
const AskAIPageClient = dynamic(loadAskAIPage, { ssr: false, loading: AskAILoadingBody })

/** The original focused `/ask` chrome, now containing the assistant-ui runtime. */
export function AskPageClient() {
  const router = useRouter()
  const allowPrefetch = useSpeculativeLoading()
  const searchParams = useSearchParams()
  const { t } = useTranslation()
  // Blank → "Ask AI"; once a thread has a subject, show it here (summarized by CSS truncation).
  const [headerTitle, setHeaderTitle] = useState<string | null>(null)
  const [contentReady, setContentReady] = useState(false)
  // The assistant-ui thread runtime is client-only; rendering it during SSR causes a hydration
  // mismatch. Gate it on the hydration flag so the server and first client render agree (no thread),
  // then mount it after hydration.
  const hydrated = useHydrated()

  // Load the assistant runtime alongside guest authentication, rather than
  // parsing it in the entry bundle before the auth boundary can even mount.
  useEffect(() => {
    void loadAskAIPage().catch(() => undefined)
  }, [])

  const handleClose = useCallback(() => {
    const returnHref = resolveAskAICloseHref(searchParams.get("return"))
    // Soft dismiss: prefer history back when Ask was pushed on top of the return
    // page so Next can restore the prior tree instead of cold-remounting it.
    if (typeof window !== "undefined" && window.history.length > 1) {
      const returnPath = returnHref.split("?")[0] ?? returnHref
      const openedFromReturn = sessionStorage.getItem("avana:ask-ai-opened-from") === returnHref
      if (openedFromReturn) {
        sessionStorage.removeItem("avana:ask-ai-opened-from")
        router.back()
        return
      }
      // Fallback when the marker is missing but the referrer path still matches.
      if (document.referrer) {
        try {
          const ref = new URL(document.referrer)
          if (ref.origin === window.location.origin && ref.pathname === returnPath) {
            router.back()
            return
          }
        } catch {
          // ignore invalid referrer
        }
      }
    }
    router.push(returnHref)
  }, [router, searchParams])

  useEffect(() => {
    if (allowPrefetch) router.prefetch(resolveAskAICloseHref(searchParams.get("return")))
  }, [allowPrefetch, router, searchParams])

  // Keyboard shortcuts: Esc closes /ask, "/" focuses the composer — but only when
  // the user is not already typing in a field, so a draft is never lost.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null
      const typing =
        !!target && (target.tagName === "TEXTAREA" || target.tagName === "INPUT" || target.isContentEditable)
      if (event.key === "Escape" && !typing) {
        event.preventDefault()
        handleClose()
      } else if (event.key === "/" && !typing) {
        event.preventDefault()
        document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Ask Avana a question"]')?.focus()
      }
    }
    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [handleClose])

  return (
    <div className="flex min-h-[100dvh] flex-col bg-background text-foreground">
      <header className="sticky top-0 z-40 flex h-14 items-center border-b border-border bg-background px-4 text-foreground sm:px-6 lg:h-14 lg:px-5 xl:px-6 2xl:px-8">
        <Link href="/" aria-label={t("Home")} title={t("Home")} className="inline-flex min-w-0 items-center">
          <BrandIcon className="xl:hidden" />
          <BrandLogo className="hidden xl:inline-flex" visibleFrom="xl" />
        </Link>

        <div className="pointer-events-none absolute left-1/2 w-[min(520px,calc(100%-128px))] -translate-x-1/2 text-center sm:w-[min(560px,calc(100%-192px))]">
          {contentReady ? (
            <div className="truncate text-[18px] font-normal leading-6 tracking-[-0.01em] text-foreground">
              {headerTitle ?? t("Ask AI")}
            </div>
          ) : (
            <AskAIHeaderTitleSkeleton />
          )}
        </div>

        <button
          type="button"
          aria-label={t("Close")}
          onClick={handleClose}
          className="ml-auto inline-flex size-11 items-center justify-center rounded-full border border-brand/25 bg-brand text-white shadow-elev-1 transition-colors hover:bg-brand/90"
        >
          <X className="size-5" />
        </button>
      </header>

      <AskAIConvexBoundary>
        {hydrated ? (
          <AskAIPageClient onActiveTitleChange={setHeaderTitle} onReadyChange={setContentReady} />
        ) : (
          <AskAILoadingBody />
        )}
      </AskAIConvexBoundary>
    </div>
  )
}
