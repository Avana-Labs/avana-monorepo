"use client"

import { AnimatedTextValue } from "@/app/components/action-page/action-live-value"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ActionTokenIcon, ActionTokenPairIcon } from "@/app/components/action-page/action-token-icon"
import { ACTION_FIELD_SURFACE_CLASS } from "@/app/components/action-page/action-surface-tokens"

export function ActionContextSelectorCard({
  label,
  value,
  approxUsdLabel,
  collateralSymbol,
  borrowSymbol,
  onClick,
  switchable = true,
}: {
  label: string
  value: string
  approxUsdLabel?: string
  collateralSymbol: string
  borrowSymbol?: string
  onClick: () => void
  /** False once the choice is locked in (Review onward): no chevron, not clickable. */
  switchable?: boolean
  /** Retained for call-site compatibility; the card now matches SwapStyleField
   *  padding/label in every layout so the collateral card is flush with the
   *  amount fields around it. */
  workspace?: boolean
}) {
  const { t } = useTranslation()
  return (
    <button
      type="button"
      onClick={switchable ? onClick : undefined}
      disabled={!switchable}
      className="w-full text-left disabled:cursor-default"
      data-testid="action-context-selector-card"
    >
      {/* Match SwapStyleField exactly (surface padding, 15px label, mt-1.5/mt-1 spacing)
          so the collateral card has the same rhythm as the amount/percent fields it sits
          beside — on the homepage, the detail-page sidebars, and the full action pages. */}
      <div className={`${ACTION_FIELD_SURFACE_CLASS} border border-border bg-field-top`}>
        <div className="text-[15px] font-normal leading-5 text-foreground/70">{t(label)}</div>
        {/* container-type set inline (Tailwind here doesn't emit @container) so the pair
            name below can size off the CARD width via cqi — shrinking to fit the narrow
            detail-page sidebar instead of truncating, while staying large on the
            full-width action page. */}
        <div
          style={{ containerType: "inline-size" }}
          className="mt-1.5 flex items-center justify-between gap-3 max-[360px]:flex-col max-[360px]:items-start"
        >
          <div className="min-w-0 flex-1 break-words text-[clamp(0.95rem,7cqi,2rem)] font-medium leading-none tracking-[-0.04em] text-foreground min-[361px]:truncate">
            {value}
          </div>
          <div className="inline-flex h-11 shrink-0 items-center gap-1.5 rounded-full border border-border bg-background px-3 text-[14px] font-medium dark:bg-card max-[360px]:self-end">
            {borrowSymbol ? (
              <ActionTokenPairIcon collateralSymbol={collateralSymbol} borrowSymbol={borrowSymbol} size="pill" />
            ) : (
              <ActionTokenIcon symbol={collateralSymbol} size="pill" />
            )}
            {/* Label so the chevron hugs text like every other selector pill
                (icon + label + chevron). LP pairs read "LP"; a single-asset
                collateral shows its ticker. */}
            <span>{borrowSymbol ? "LP" : collateralSymbol}</span>
            {switchable ? (
              <span className="text-muted-foreground" aria-hidden>
                ▾
              </span>
            ) : null}
          </div>
        </div>
        {approxUsdLabel ? (
          <div className="mt-1 text-[14px] leading-5 text-foreground/60">
            <AnimatedTextValue text={approxUsdLabel} />
          </div>
        ) : null}
      </div>
    </button>
  )
}
