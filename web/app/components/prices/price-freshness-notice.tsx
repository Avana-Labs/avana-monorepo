"use client"

import { AlertTriangle } from "@/app/components/icons"
import { usePriceFreshness } from "@/app/lib/prices/token-prices-context"
import { useTranslation } from "@/app/lib/i18n/use-translation"

/**
 * Surfaces oracle staleness so last-known prices are never presented as live. Renders nothing
 * while prices are fresh (or before the status query resolves / when no oracle is mounted), and a
 * subtle warning row once the newest price row ages past the stale threshold — i.e. when the 10-min
 * refresh cron has wedged. Consumes usePriceFreshness, which derives age against a ticking clock.
 */
export function PriceFreshnessNotice({ className }: { className?: string }) {
  const { stale } = usePriceFreshness()
  const { t } = useTranslation()
  if (!stale) return null
  return (
    <div
      role="status"
      className={`flex items-center gap-2 text-[12px] text-amber-600 dark:text-amber-400 ${className ?? ""}`}
    >
      <AlertTriangle className="h-3.5 w-3.5 shrink-0" aria-hidden="true" />
      <span>{t("Prices may be stale")}</span>
    </div>
  )
}
