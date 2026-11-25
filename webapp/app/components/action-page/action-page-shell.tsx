"use client"

import { X } from "@/app/components/icons"
import { useRouter } from "next/navigation"
import { useEffect, type ReactNode } from "react"
import { cn } from "@/lib/utils"
import type { ActionPageMode, ActionStage } from "@/app/lib/action-system/contracts"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ActionFlowHeader } from "@/app/components/action-page/action-flow-header"

type ActionPageShellProps = {
  mode?: ActionPageMode
  density?: "default" | "sidebar" | "home"
  title: string
  subtitle?: string
  hideTitle?: boolean
  hideClose?: boolean
  flowHeaderStage?: ActionStage
  /** False for flows with no Select stage, so the header reads "Step 1 of 3". */
  flowHeaderHasSelectStep?: boolean
  flowHeaderMobileOnly?: boolean
  onClose?: () => void
  closeHref?: string
  children: ReactNode
  footer?: ReactNode
  className?: string
}

export function ActionPageShell({
  mode = "page",
  density = "default",
  title,
  subtitle,
  hideTitle = false,
  hideClose = false,
  flowHeaderStage,
  flowHeaderHasSelectStep = true,
  flowHeaderMobileOnly = false,
  onClose,
  closeHref,
  children,
  footer,
  className,
}: ActionPageShellProps) {
  const router = useRouter()
  const { t } = useTranslation()
  const showChrome = true
  const showTitleBlock = showChrome && !hideTitle
  const showFlowHeader = showChrome && !hideClose && flowHeaderStage != null

  // Full-screen action flows open as their own route (the table/hero "popup" CTAs
  // navigate here), but Next preserves the launching page's window scroll — so the
  // flow would open mid-scroll with its header cut off. Reset to the top on mount.
  // Embedded flows live inside another scroll context, so leave those untouched.
  useEffect(() => {
    if (mode === "page" || mode === "overlay") {
      window.scrollTo(0, 0)
    }
  }, [mode])

  const handleClose = () => {
    if (onClose) {
      onClose()
      return
    }
    if (closeHref) {
      router.push(closeHref)
    }
  }

  return (
    <div
      className={cn(
        "flex min-h-0 w-full flex-col bg-background text-foreground",
        mode === "page" && "min-h-[100dvh]",
        mode === "overlay" && "fixed inset-0 z-50 min-h-[100dvh]",
        mode === "embedded" && density === "sidebar" && "rounded-none border-0 bg-transparent shadow-none",
        mode === "embedded" && density === "home" && "rounded-none border-0 bg-transparent shadow-none",
        mode === "embedded" && density === "default" && "rounded-radius-md",
        className,
      )}
      data-testid="action-page-shell"
      data-mode={mode}
    >
      {showFlowHeader ? (
        <ActionFlowHeader
          stage={flowHeaderStage}
          onClose={handleClose}
          mobileOnly={flowHeaderMobileOnly}
          hasSelectStep={flowHeaderHasSelectStep}
        />
      ) : null}

      {showChrome && !hideClose && !showFlowHeader ? (
        <div className="flex items-center justify-end gap-1.5 px-4 pb-1 pt-3 sm:px-6">
          <button
            type="button"
            aria-label={t("Close")}
            onClick={handleClose}
            className="inline-flex size-11 items-center justify-center rounded-full border border-border/60 bg-surface-2/60 text-muted-foreground shadow-elev-1 backdrop-blur-md transition-colors hover:bg-hover hover:text-foreground"
          >
            <X className="size-5" />
          </button>
        </div>
      ) : null}

      <div
        className={cn(
          "mx-auto flex w-full flex-1 flex-col",
          density === "home" && "max-w-none gap-2 px-0 pb-0",
          density === "sidebar" && "max-w-none gap-4 px-0 pb-0",
          density === "default" && "max-w-[560px] gap-4 px-4 pb-[calc(env(safe-area-inset-bottom)+1rem)] sm:px-6",
          showFlowHeader && density === "default" && "pt-12",
          showFlowHeader && flowHeaderMobileOnly && density === "default" && "lg:pt-0",
        )}
      >
        {showTitleBlock ? (
          <div className="pb-5">
            <h1 className="text-[1.5rem] font-semibold tracking-[-0.03em] text-foreground sm:text-[1.625rem]">
              {t(title)}
            </h1>
            {subtitle ? (
              <p className="mt-1.5 text-[15px] leading-relaxed text-muted-foreground">{t(subtitle)}</p>
            ) : null}
          </div>
        ) : null}

        {/* One consistent gap between the stacked cards on every surface — the tight
            homepage rhythm (gap-2), not the roomier gap-4 the sidebar/full action
            pages used before. */}
        <div className={cn("flex min-h-0 flex-1 flex-col gap-2")}>{children}</div>

        {footer ? <div className="mt-4">{footer}</div> : null}
      </div>
    </div>
  )
}
