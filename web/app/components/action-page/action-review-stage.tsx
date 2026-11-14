"use client"

import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"
import { resolveActionAmountCardProps } from "@/app/lib/action-system/action-amount-display"
import { ActionOutcomeBanner, ActionRiskBanner } from "@/app/components/action-page/action-banners"
import { ActionAmountCard } from "@/app/components/action-page/action-amount-card"
import { ActionCard, ActionInfoRow, ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { ActionFooter } from "@/app/components/action-page/action-amount-card"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export function ActionReviewStage({
  title,
  subtitle,
  preview,
  primaryLabel = "Confirm",
  onPrimary,
  secondaryLabel = "Back",
  onSecondary,
  secondaryHref,
  hideHeader = false,
  primaryPending = false,
  blockedReason = null,
  confirmationGate,
  amountVariant = "raised",
}: {
  title: string
  subtitle?: string
  preview: ActionPreviewUi
  primaryLabel?: string
  onPrimary?: () => void
  secondaryLabel?: string
  onSecondary?: () => void
  secondaryHref?: string
  hideHeader?: boolean
  primaryPending?: boolean
  /** When set (e.g. wrong network), hard-disable the confirm CTA and show the reason. */
  blockedReason?: string | null
  confirmationGate?: {
    checked: boolean
    onCheckedChange: (checked: boolean) => void
    label: string
  }
  amountVariant?: "card" | "inset" | "raised"
}) {
  const { t } = useTranslation()
  const amountDisplay = resolveActionAmountCardProps(preview)
  const isClaimReview = preview.rateLabel === "Claim total"
  const riskShown = !isClaimReview && Boolean(preview.risk?.title && preview.risk.message)
  // The risk banner already surfaces warnings[0] for leveraged actions, so suppress the
  // duplicate "Note" row when it repeats the message the banner is showing.
  const noteWarning =
    preview.warnings[0] && !(riskShown && preview.warnings[0] === preview.risk?.message) ? preview.warnings[0] : null

  return (
    <div className="space-y-4" data-testid="action-review-stage">
      {!hideHeader ? (
        <div className="pb-1">
          <h2 className="text-ui-heading font-semibold tracking-[-0.03em] text-foreground">{t(title)}</h2>
          {subtitle ? <p className="mt-1.5 text-[15px] leading-relaxed text-muted-foreground">{t(subtitle)}</p> : null}
        </div>
      ) : null}

      {isClaimReview ? (
        <ActionCard>
          <ActionInfoRow label="Claim total" value={preview.rateValue} tooltip="claimTotal" />
          <ActionInfoRow label="Market" value={preview.marketValue} tooltip="market" />
        </ActionCard>
      ) : (
        <ActionAmountCard
          label={preview.amountTitle ?? "Amount"}
          amount={amountDisplay.amount}
          onAmountChange={() => undefined}
          approxUsdLabel={preview.amountUsdLabel}
          assetLabel={amountDisplay.assetLabel}
          assetSymbol={amountDisplay.assetSymbol}
          borrowSymbol={amountDisplay.borrowSymbol}
          unitLabel={preview.amountUnitLabel}
          readOnly
          variant={amountVariant}
        />
      )}

      {isClaimReview ? null : (preview.rateLabel && preview.rateValue) ||
        preview.marketBreakdown ||
        preview.marketValue ? (
        <ActionCard>
          {preview.rateLabel && preview.rateValue ? (
            <ActionInfoRow
              label={preview.rateLabel}
              value={preview.rateValue}
              tooltip={/rate/i.test(preview.rateLabel) && /=/.test(preview.rateValue) ? "fxRate" : "rate"}
            />
          ) : null}
          {preview.marketBreakdown ? (
            <>
              <ActionInfoRow
                label="Collateral APY"
                value={`${preview.marketBreakdown.collateral.symbol} · ${preview.marketBreakdown.collateral.apy}`}
                tooltip="collateralApy"
              />
              <ActionInfoRow
                label="Borrow APY"
                value={`${preview.marketBreakdown.borrow.symbol} · ${preview.marketBreakdown.borrow.apy}`}
                tooltip="borrowApy"
              />
            </>
          ) : preview.marketValue ? (
            <ActionInfoRow label="Market" value={preview.marketValue} tooltip="market" />
          ) : null}
        </ActionCard>
      ) : null}

      {preview.metrics.length > 0 ? <ActionMetricsBlock rows={preview.metrics} /> : null}

      {riskShown ? (
        <ActionRiskBanner level={preview.risk!.level} title={preview.risk!.title!} message={preview.risk!.message!} />
      ) : null}

      {noteWarning ? (
        <ActionCard>
          <ActionInfoRow label="Note" value={noteWarning} />
        </ActionCard>
      ) : null}

      <ActionCard>
        <ActionInfoRow label="Avana Platform Fee" value={preview.networkFeeLabel} tooltip="fee" />
      </ActionCard>

      {blockedReason ? <ActionOutcomeBanner tone="error" title="Action unavailable" message={blockedReason} /> : null}

      {confirmationGate ? (
        <label className="flex cursor-pointer items-start gap-3 rounded-radius-xl border border-danger/30 bg-danger/10 p-4 text-[13px] leading-relaxed text-foreground">
          <input
            type="checkbox"
            checked={confirmationGate.checked}
            onChange={(event) => confirmationGate.onCheckedChange(event.target.checked)}
            className="mt-0.5 size-4 shrink-0 accent-[hsl(var(--brand))]"
          />
          <span>{t(confirmationGate.label)}</span>
        </label>
      ) : null}

      <ActionFooter
        primaryLabel={primaryLabel}
        secondaryLabel={secondaryLabel}
        onPrimary={onPrimary}
        onSecondary={onSecondary}
        secondaryHref={secondaryHref}
        primaryDisabled={
          (!preview.allowed && Boolean(preview.blockedReason)) ||
          Boolean(blockedReason) ||
          Boolean(confirmationGate && !confirmationGate.checked)
        }
        primaryPending={primaryPending}
        sticky
      />
    </div>
  )
}
