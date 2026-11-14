"use client"

import { useEffect, useRef, useState } from "react"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { UmbrellaSidebar } from "./sidebars/UmbrellaSidebar"

export type UmbrellaMobileSheetTrigger = "stake" | "cooldown" | "unstake" | "claim"

/**
 * Mobile-only bottom sheet that surfaces the umbrella action sidebar. Reuses
 * the shared shadcn Dialog primitive (Radix under the hood → focus trap + ESC
 * + backdrop click for free) with `fullScreenOnMobile` so it fills the viewport
 * on small screens and falls back to a centered dialog on tablet+.
 *
 * The mobile action bar in /umbrella lifts this to swap between Stake and
 * Unstake; on desktop the sheet never renders because the aside sidebar takes
 * over (lg:block on the parent aside).
 */
export function UmbrellaMobileSidebarSheet({
  open,
  onOpenChange,
  moduleId,
  onMarketChange,
  initialTab = "stake",
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  moduleId: UmbrellaMarketId
  onMarketChange?: (marketId: UmbrellaMarketId) => void
  // The trigger the user tapped in the mobile action bar. Threaded into
  // UmbrellaSidebar as its `initialTab` so Stake/Unstake open on the matching tab
  // instead of always landing on Stake. The sidebar is remounted on every open (see the
  // `sessionKey` below), so the new initialTab takes effect each time.
  initialTab?: UmbrellaMobileSheetTrigger
}) {
  // Force a remount of UmbrellaSidebar when the sheet is (re)opened so the
  // Stake/Cooldown/Unstake tab lands on the trigger's default. Closing a sheet
  // shouldn't wipe unsaved input if the user just backgrounded it — but from
  // a mobile-nav POV, tapping a different bar button means "start there".
  const { t } = useTranslation()
  const sessionRef = useRef(0)
  const [sessionKey, setSessionKey] = useState(0)
  useEffect(() => {
    if (!open) return
    sessionRef.current += 1
    setSessionKey(sessionRef.current)
  }, [open])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        fullScreenOnMobile
        aria-label={t("Umbrella actions")}
        className="max-md:flex max-md:flex-col max-md:overflow-hidden md:max-w-[420px] md:rounded-radius-lg md:p-4"
      >
        <DialogTitle className="sr-only">{t("Umbrella actions")}</DialogTitle>
        <DialogDescription className="sr-only">
          {t("Stake, claim rewards, start cooldown, or unstake from the umbrella safety module.")}
        </DialogDescription>
        <div className="flex items-center justify-between border-b border-border px-4 py-3 max-md:pt-6 md:hidden">
          <div>
            <div className="text-[14px] font-semibold text-foreground">{t("Umbrella")}</div>
            <div className="text-[11px] text-muted-foreground">{t("Stake, claim, cooldown, unstake")}</div>
          </div>
          <button
            type="button"
            onClick={() => onOpenChange(false)}
            aria-label={t("Close umbrella actions")}
            className="h-8 rounded-radius-sm border border-border bg-surface-raised px-3 text-[12px] font-medium text-foreground hover:bg-surface-hover"
          >
            {t("Close")}
          </button>
        </div>
        <div className="flex-1 overflow-y-auto px-4 pb-[calc(1rem+env(safe-area-inset-bottom))] pt-3 md:px-0 md:pt-0">
          <UmbrellaSidebar
            key={sessionKey}
            moduleId={moduleId}
            onMarketChange={onMarketChange}
            initialTab={initialTab}
          />
        </div>
      </DialogContent>
    </Dialog>
  )
}
