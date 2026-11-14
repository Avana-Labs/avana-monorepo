"use client"

import { useTranslation } from "@/app/lib/i18n/use-translation"

export function shouldShowActionSessionLoading(isHydrated: boolean | undefined) {
  return isHydrated === false
}

export function ActionSessionLoading() {
  const { t } = useTranslation()
  return (
    <div role="status" aria-live="polite" className="space-y-4" data-testid="action-session-loading">
      <span className="sr-only">{t("Loading wallet position")}</span>
      <div className="h-28 animate-pulse rounded-radius-lg bg-surface-inset" />
      <div className="grid grid-cols-2 gap-3">
        <div className="h-20 animate-pulse rounded-radius-lg bg-surface-inset" />
        <div className="h-20 animate-pulse rounded-radius-lg bg-surface-inset" />
      </div>
      <div className="h-12 animate-pulse rounded-radius-lg bg-surface-inset" />
    </div>
  )
}
