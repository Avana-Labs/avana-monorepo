"use client"

import { useState } from "react"
import Link from "next/link"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import { formatHealthFactor } from "@/app/lib/data/borrow-domain"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type HealthRiskProduct = "borrow" | "multiply"

/**
 * Proactive, dismissible banner shown inside the matching product tab, directly
 * beneath its health heading, when a position lands in the shared `danger` or
 * `watch` band. It deep-links to the action that reduces risk for that product —
 * Repay for borrow, Deleverage for multiply. All tones come from the shared health
 * band (no invented colours) so it reads consistently with the HF bars elsewhere.
 */
export function HealthRiskBanner({
  healthFactor,
  product,
}: {
  healthFactor: number | null
  product: HealthRiskProduct
}) {
  const { t } = useTranslation()
  const [dismissed, setDismissed] = useState(false)

  const band = healthFactorBand(healthFactor)
  if (dismissed) return null
  if (band.id !== "danger" && band.id !== "watch") return null

  const href = product === "multiply" ? "/actions/multiply/deleverage" : "/actions/borrow/repay"
  const actionLabel = product === "multiply" ? t("Deleverage") : t("Repay")

  return (
    <div
      role="alert"
      className={`flex flex-wrap items-start justify-between gap-3 rounded-radius-md border ${band.bar.border} bg-card px-4 py-3 shadow-elev-1`}
    >
      <div className="flex min-w-0 items-start gap-2.5">
        <span className={`mt-0.5 text-[16px] leading-none ${band.bar.text}`} aria-hidden="true">
          ⚠
        </span>
        <div className="min-w-0">
          <p className="text-[13px] font-medium text-foreground">
            {t("A position is near liquidation (health factor {hf}).").replace(
              "{hf}",
              formatHealthFactor(healthFactor),
            )}
          </p>
          <p className="mt-0.5 text-[12px] text-muted-foreground">
            {t("Repay or add collateral to reduce your liquidation risk.")}
          </p>
        </div>
      </div>
      <div className="flex items-center gap-2">
        <Link
          href={href}
          className={`inline-flex h-8 items-center rounded-radius-sm border ${band.bar.border} px-3 text-[12px] font-normal ${band.bar.text}`}
        >
          {actionLabel}
        </Link>
        <button
          type="button"
          onClick={() => setDismissed(true)}
          aria-label={t("Dismiss")}
          className="inline-flex h-8 w-8 items-center justify-center rounded-radius-sm text-[16px] leading-none text-muted-foreground hover:text-foreground"
        >
          ×
        </button>
      </div>
    </div>
  )
}
