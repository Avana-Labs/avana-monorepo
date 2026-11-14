"use client"

import { AnimatedTextValue } from "@/app/components/action-page/action-live-value"
import type { HomeCollateralPool } from "@/app/lib/home-sim"
import { formatActionApproxUsd } from "@/app/lib/action-system/formatters"
import { ActionContextSelectorCard } from "@/app/components/action-page/action-context-selector-card"
import { ActionTokenPairIcon } from "@/app/components/action-page/action-token-icon"
import { SwapStyleField } from "@/app/components/action-page/swap-style-field"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

export function HomeActionContextBar({
  pool,
  onOpenPool,
  variant = "card",
  workspace = false,
  label = "Collateral",
  switchable = true,
}: {
  pool: HomeCollateralPool | null
  onOpenPool: () => void
  variant?: "card" | "inset"
  workspace?: boolean
  label?: string
  switchable?: boolean
}) {
  const { t } = useTranslation()
  // Render one card in every state so the collateral input looks identical whether
  // or not the wallet already holds collateral in the selected market. When no pool
  // is selected yet, show a clear placeholder + $0 instead of a different card.
  const [collateralSymbol, borrowSymbol] = pool ? pool.visuals.map((visual) => visual.symbol) : []
  const valueLabel = pool ? pool.name : "0"
  const approxUsdLabel = formatActionApproxUsd(pool?.collateralUsd ?? 0)

  if (variant === "inset") {
    return (
      <SwapStyleField label={t(label)} tone="raised">
        <button
          type="button"
          onClick={switchable ? onOpenPool : undefined}
          disabled={!switchable}
          style={{ containerType: "inline-size" }}
          className="mt-1.5 flex w-full items-center justify-between gap-3 text-left disabled:cursor-default max-[360px]:flex-col max-[360px]:items-start"
        >
          {/* Size off the card width (cqi) so long pair names fit narrow layouts. */}
          <div
            className={cn(
              "min-w-0 flex-1 break-words text-[clamp(0.95rem,7cqi,2rem)] font-normal leading-none tracking-[-0.02em] min-[361px]:truncate",
              pool ? "text-foreground" : "text-muted-foreground/60",
            )}
          >
            {valueLabel}
          </div>
          <div className="inline-flex h-11 shrink-0 items-center gap-1.5 rounded-full border border-border bg-surface-raised px-3 text-[14px] font-normal leading-5 max-[360px]:self-end">
            {pool ? (
              <>
                <ActionTokenPairIcon
                  collateralSymbol={collateralSymbol ?? "LP"}
                  borrowSymbol={borrowSymbol ?? "LP"}
                  size="pill"
                />
                {/* Label so the chevron hugs text like the other selector pills. */}
                <span>LP</span>
              </>
            ) : (
              <span>{t("Select Pool")}</span>
            )}
            {switchable ? (
              <span className="text-muted-foreground" aria-hidden>
                ▾
              </span>
            ) : null}
          </div>
        </button>
        <div className="mt-1 text-[14px] leading-5 text-foreground/60">
          <AnimatedTextValue text={approxUsdLabel} />
        </div>
      </SwapStyleField>
    )
  }

  // No wrapper margin: the card stack (ActionPageShell) already spaces this card
  // from the next with gap-2. A stray mb-3 here made the collateral→amount gap
  // bigger than every other card gap.
  return (
    <ActionContextSelectorCard
      label={t(label)}
      value={valueLabel}
      approxUsdLabel={approxUsdLabel}
      collateralSymbol={collateralSymbol ?? "LP"}
      borrowSymbol={borrowSymbol}
      onClick={onOpenPool}
      switchable={switchable}
      workspace={workspace}
    />
  )
}
