"use client"

import { useEffect, useState, type ReactNode } from "react"
import Link from "next/link"
import type { ActionPreviewUi, ActionStage } from "@/app/lib/action-system/contracts"
import { ActionAmountCard, ActionFooter, type ActionAssetOption } from "@/app/components/action-page/action-amount-card"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import { cn } from "@/lib/utils"
import { parsePositiveActionAmount } from "@/app/lib/action-system/amount-input"
import { ActionLeverageRuler } from "@/app/components/action-page/action-leverage-ruler"
import { ActionOutcomeBanner, ActionRiskBanner, ActionWalletToast } from "@/app/components/action-page/action-banners"
import { ActionCard, ActionInfoRow, ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { ActionHealthFactorBar } from "@/app/components/action-page/action-health-factor-bar"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TRANSACT_ACCESS_HREF, useTransactAccessCta } from "@/app/lib/transact-access"
import { isHealthFactorMetric, parseHealthFactorValue } from "@/app/lib/action-system/health-factor-ui"
import {
  isConfigureVisibleStage,
  primaryCtaLabel,
  secondaryCtaLabel,
  shouldDisablePrimaryCta,
  shouldShowWalletToast,
  walletToastMessage,
} from "@/app/lib/action-system/stage-machine"

function formatBlockedOutcomeMessage(blockedReason: string, balanceValue?: string | null) {
  const normalizedBalance = balanceValue?.replace(/[^\d.]/g, "") ?? ""
  const isZeroBalance = normalizedBalance === "" || normalizedBalance === "0" || /^0\.0+$/.test(normalizedBalance)
  const isBalanceBlock = /insufficient/i.test(blockedReason) || /balance/i.test(blockedReason.toLowerCase())
  if (isBalanceBlock && isZeroBalance) {
    return `${blockedReason} Fund your wallet or switch accounts to continue.`
  }
  return blockedReason
}

type ActionConfigureStageProps = {
  stage: ActionStage
  verb: string
  amount: string
  onAmountChange: (value: string) => void
  inputLabel?: string
  /** Override the "~ USD" line under the amount. Used where the field shows a quantity the
   *  preview's own amountUsd does not describe (Multiply close/deleverage show COLLATERAL,
   *  while the preview's amount is the withdrawal / target leverage). */
  amountUsdLabel?: string
  /** Render this in the amount field INSTEAD of `amount`, without touching validation.
   *  `amount` still drives amountEntered / CTA state, so a read-only informational value
   *  (Multiply close/deleverage show the position's collateral) cannot make an empty,
   *  invalid form look filled in. */
  displayAmount?: string
  preview: ActionPreviewUi | null
  assetSymbol?: string
  borrowSymbol?: string
  onPrimary?: () => void
  onSecondary?: () => void
  secondaryHref?: string
  showReceiveWethToggle?: boolean
  receiveWeth?: boolean
  onReceiveWethChange?: (value: boolean) => void
  isPending?: boolean
  outcome?: { tone: "error" | "success"; title: string; message: string } | null
  assetOptions?: ActionAssetOption[]
  selectedAssetId?: string
  onAssetSelect?: (id: string) => void
  multiplier?: string
  onMultiplierChange?: (value: string) => void
  multiplierMin?: number
  multiplierMax?: number
  multiplierStep?: number
  multiplierLabel?: string
  multiplierValueSuffix?: string
  multiplierSubvalue?: string
  canGoBack?: boolean
  hideAmountInput?: boolean
  amountReadOnly?: boolean
  amountVariant?: "card" | "inset" | "raised"
  amountFooter?: ReactNode
  showBalance?: boolean
  onMax?: () => void
  /** Explicit balance line; falls back to the preview's balance when omitted. */
  balanceLabel?: string
  balanceValue?: string
  assetLabel?: string
  amountUnitLabel?: string
  hideAssetSelector?: boolean
  homeLayout?: boolean
  /** Render a single primary CTA (no Cancel/secondary) without adopting the rest
   *  of the compact home layout. Used by the detail-page sidebar rail, which is a
   *  pre-loaded full-page action and has no select stage to cancel back to. */
  singlePrimaryCta?: boolean
  /** Claim flow: surface the claimable total + market + token breakdown on the
   *  home/sidebar configure screen (which otherwise hides preview detail cards). */
  claimSummary?: boolean
  amountPlacement?: "inline" | "stacked"
  assetPickerVariant?: "menu" | "dialog"
  pickerTokens?: import("@/app/lib/borrow-system/home-contracts").HomeBorrowToken[]
  assetPickerDisabled?: boolean
  assetPickerHint?: string
  onAssetPickerBlocked?: () => void
  /** Product-specific detail content that replaces the generic rate/market/metrics
   *  block (e.g. the Umbrella market-risk card). The risk banner + network fee row
   *  still render around it. */
  detailsSlot?: ReactNode
  /** Progressive disclosure: when true, the risk banner and network-fee row stay
   *  hidden until the user has entered an amount, keeping the empty state clean.
   *  (detailsSlot content is always shown — the slot decides its own reveal.) */
  deferDetailsUntilAmount?: boolean
  /** Fade/slide-in the details block when the preview mounts. Defaults to true;
   *  pass false for a static reveal (e.g. the Umbrella market-risk stats). */
  animateDetails?: boolean
  /** Keep the asset picker interactive even when the amount is read-only (Claim). */
  allowAssetSwitchWhenReadOnly?: boolean
  /** Reason shown on the CTA when there is no position to act on and the preview is therefore
   *  null (e.g. "Nothing to repay"). Mapped to a short label via blockedCtaLabel. */
  emptyReason?: string | null
}

export function ActionConfigureAmountSection({
  verb,
  amount,
  onAmountChange,
  preview,
  assetSymbol,
  borrowSymbol,
  showReceiveWethToggle = false,
  receiveWeth = false,
  onReceiveWethChange,
  assetOptions,
  selectedAssetId,
  onAssetSelect,
  amountReadOnly = false,
  amountVariant = "raised",
  hideAssetSelector = false,
  assetPickerVariant = "menu",
  pickerTokens,
  assetPickerDisabled,
  assetPickerHint,
  onAssetPickerBlocked,
  amountFooter,
  showBalance = false,
  onMax,
  balanceLabel,
  balanceValue,
  assetLabel,
  amountUnitLabel,
  inputLabel,
  amountUsdLabel,
  displayAmount,
  allowAssetSwitchWhenReadOnly,
}: Pick<
  ActionConfigureStageProps,
  | "verb"
  | "amount"
  | "onAmountChange"
  | "inputLabel"
  | "amountUsdLabel"
  | "displayAmount"
  | "preview"
  | "assetSymbol"
  | "borrowSymbol"
  | "showReceiveWethToggle"
  | "receiveWeth"
  | "onReceiveWethChange"
  | "assetOptions"
  | "selectedAssetId"
  | "onAssetSelect"
  | "amountReadOnly"
  | "amountVariant"
  | "hideAssetSelector"
  | "assetPickerVariant"
  | "pickerTokens"
  | "assetPickerDisabled"
  | "assetPickerHint"
  | "onAssetPickerBlocked"
  | "amountFooter"
  | "showBalance"
  | "onMax"
  | "balanceLabel"
  | "balanceValue"
  | "assetLabel"
  | "amountUnitLabel"
  | "allowAssetSwitchWhenReadOnly"
>) {
  const { exact } = useCurrency()
  const pillLabel = assetLabel ?? assetSymbol ?? preview?.amountLabel.split(" ").slice(-1)[0] ?? "Asset"

  return (
    <ActionAmountCard
      label={inputLabel ?? verb}
      amount={displayAmount ?? amount}
      onAmountChange={onAmountChange}
      approxUsdLabel={amountUsdLabel ?? preview?.amountUsdLabel ?? exact(0)}
      assetLabel={pillLabel}
      unitLabel={amountUnitLabel}
      footer={amountFooter}
      balanceLabel={showBalance ? (balanceLabel ?? preview?.balanceLabel) : undefined}
      balanceValue={showBalance ? (balanceValue ?? preview?.balanceValue) : undefined}
      onMax={showBalance ? onMax : undefined}
      assetSymbol={assetSymbol ?? pillLabel}
      borrowSymbol={borrowSymbol}
      readOnly={amountReadOnly}
      variant={amountVariant}
      hideAssetSelector={hideAssetSelector}
      showReceiveWethToggle={showReceiveWethToggle}
      receiveWeth={receiveWeth}
      onReceiveWethChange={onReceiveWethChange}
      assetOptions={assetOptions}
      selectedAssetId={selectedAssetId}
      onAssetSelect={onAssetSelect}
      assetPickerVariant={assetPickerVariant}
      pickerTokens={pickerTokens}
      assetPickerDisabled={assetPickerDisabled}
      assetPickerHint={assetPickerHint}
      onAssetPickerBlocked={onAssetPickerBlocked}
      allowAssetSwitchWhenReadOnly={allowAssetSwitchWhenReadOnly}
    />
  )
}

export function ActionConfigureStage({
  stage,
  verb,
  amount,
  onAmountChange,
  preview,
  assetSymbol,
  borrowSymbol,
  onPrimary,
  onSecondary,
  secondaryHref,
  showReceiveWethToggle = false,
  receiveWeth = false,
  onReceiveWethChange,
  isPending = false,
  outcome = null,
  assetOptions,
  selectedAssetId,
  onAssetSelect,
  multiplier,
  onMultiplierChange,
  multiplierMin = 1,
  multiplierMax = 20,
  multiplierStep = 0.1,
  multiplierLabel = "Multiplier",
  multiplierValueSuffix,
  multiplierSubvalue,
  canGoBack = false,
  hideAmountInput = false,
  amountReadOnly = false,
  amountVariant = "raised",
  hideAssetSelector = false,
  homeLayout = false,
  singlePrimaryCta = false,
  claimSummary = false,
  amountPlacement = "inline",
  assetPickerVariant = "menu",
  pickerTokens,
  amountFooter,
  showBalance = false,
  onMax,
  balanceLabel,
  balanceValue,
  assetLabel,
  amountUnitLabel,
  inputLabel,
  amountUsdLabel,
  displayAmount,
  detailsSlot,
  deferDetailsUntilAmount = false,
  animateDetails = true,
  allowAssetSwitchWhenReadOnly = false,
  emptyReason,
}: ActionConfigureStageProps) {
  const { t } = useTranslation()
  const configureStage = stage === "error" ? "configure" : stage
  const isValid = Boolean(preview?.allowed)
  // Progressive disclosure (opt-in): keep the risk banner + network-fee row hidden
  // until an amount is entered, so the empty state stays clean.
  const showDeferredDetails = !deferDetailsUntilAmount || parsePositiveActionAmount(amount) != null
  // When there is no position to reduce (e.g. repay with no debt, withdraw with nothing
  // supplied), the preview is null — surface the caller's reason ("Nothing to repay") on the
  // CTA instead of the generic "Enter a valid amount", which reads like a bug.
  const blockedReason = preview?.blockedReason ?? emptyReason ?? null
  const amountEntered = parsePositiveActionAmount(amount) != null
  const primaryLabel = primaryCtaLabel({
    stage: configureStage,
    verb,
    blockedReason,
    isValid,
    amountEntered,
    blockedSymbol: assetSymbol,
  })
  const primaryDisabled = shouldDisablePrimaryCta({
    stage: configureStage,
    isValid,
    isPending,
    blockedReason,
  })
  const handlePrimary = () => {
    onPrimary?.()
  }
  // A guest (or a wallet still onboarding) keeps the form to explore quotes, but the CTA sends
  // them to the dashboard onboarding instead of submitting.
  const accessCta = useTransactAccessCta()
  const accessLabel = accessCta.label
  const secondaryLabel = secondaryCtaLabel(stage, { canGoBack })
  const walletStage = stage === "approve_allowance" || stage === "wallet_sign" ? stage : null
  const showStackedAmount = amountPlacement === "stacked"
  const showInlineAmount = !hideAmountInput && !showStackedAmount
  const showHomeDetails = !homeLayout
  const showStandaloneLeverage = Boolean(onMultiplierChange) && !(homeLayout && showStackedAmount)
  // A blocked/invalid action has no valid projection — the engine returns
  // after === before, so showing the metrics would misrepresent a SAFE, unchanged
  // position. Hide the projected metrics and let the block reason speak instead.
  const previewBlocked = Boolean(preview && !preview.allowed && preview.blockedReason)
  // Match reference UX: keep the amount card clean until the user types, then
  // surface the inline Action unavailable banner (also show for amount-less actions).
  const showBlockedBanner = previewBlocked && Boolean(blockedReason) && (hideAmountInput || amountEntered)
  const healthFactorRow = previewBlocked
    ? undefined
    : preview?.metrics.find((row) => isHealthFactorMetric(row.label, row.id))
  const healthFactorValue = parseHealthFactorValue(healthFactorRow?.after ?? healthFactorRow?.value)
  const showConfigureHealthFactor = homeLayout && isConfigureVisibleStage(configureStage) && healthFactorRow != null
  const [previewMounted, setPreviewMounted] = useState(false)

  useEffect(() => {
    if (!preview) {
      setPreviewMounted(false)
      return undefined
    }
    if (previewMounted) return undefined

    const frame = window.requestAnimationFrame(() => {
      setPreviewMounted(true)
    })

    return () => window.cancelAnimationFrame(frame)
  }, [preview, previewMounted])

  const previewMotionClassName = cn(
    "transition-all duration-500 ease-out",
    previewMounted ? "translate-y-0 opacity-100" : "translate-y-2 opacity-0",
  )

  return (
    <>
      {showInlineAmount ? (
        <ActionConfigureAmountSection
          verb={verb}
          amount={amount}
          onAmountChange={onAmountChange}
          preview={preview}
          assetSymbol={assetSymbol}
          borrowSymbol={borrowSymbol}
          showReceiveWethToggle={showReceiveWethToggle}
          receiveWeth={receiveWeth}
          onReceiveWethChange={onReceiveWethChange}
          assetOptions={assetOptions}
          selectedAssetId={selectedAssetId}
          onAssetSelect={onAssetSelect}
          amountReadOnly={amountReadOnly}
          amountVariant={amountVariant}
          hideAssetSelector={hideAssetSelector}
          assetPickerVariant={assetPickerVariant}
          pickerTokens={pickerTokens}
          amountFooter={amountFooter}
          showBalance={showBalance}
          onMax={onMax}
          balanceLabel={balanceLabel}
          balanceValue={balanceValue}
          assetLabel={assetLabel}
          amountUnitLabel={amountUnitLabel}
          inputLabel={inputLabel}
          amountUsdLabel={amountUsdLabel}
          displayAmount={displayAmount}
          allowAssetSwitchWhenReadOnly={allowAssetSwitchWhenReadOnly}
        />
      ) : null}

      {showStandaloneLeverage ? (
        <div>
          <ActionLeverageRuler
            value={multiplier ?? "3"}
            onChange={onMultiplierChange!}
            min={multiplierMin}
            max={multiplierMax}
            step={multiplierStep}
            label={multiplierLabel}
            valueSuffix={multiplierValueSuffix}
            subvalue={multiplierSubvalue}
          />
        </div>
      ) : null}

      {showConfigureHealthFactor ? (
        <div className={previewMotionClassName}>
          <ActionCard className="p-4" data-testid="action-health-factor-card">
            <ActionHealthFactorBar value={healthFactorValue} label={healthFactorRow?.label ?? "Health factor"} />
          </ActionCard>
        </div>
      ) : null}

      {/* Claim: the compact home/sidebar layout hides the generic preview cards, so
          surface the claim total + market + per-token breakdown here directly. */}
      {homeLayout && claimSummary && preview ? (
        <div className={cn(previewMotionClassName, "space-y-3")} data-testid="action-claim-summary">
          <ActionCard>
            {preview.rateLabel ? (
              <ActionInfoRow label={preview.rateLabel} value={preview.rateValue} tooltip="fee" />
            ) : null}
            {preview.marketValue ? <ActionInfoRow label="Market" value={preview.marketValue} tooltip="market" /> : null}
          </ActionCard>
          {preview.metrics.length > 0 ? <ActionMetricsBlock rows={preview.metrics} /> : null}
        </div>
      ) : null}

      {preview && showHomeDetails ? (
        <div className={cn(animateDetails ? previewMotionClassName : undefined, "space-y-3")}>
          {detailsSlot ? (
            detailsSlot
          ) : (
            <>
              {preview.rateLabel || preview.marketValue || preview.marketBreakdown ? (
                <ActionCard>
                  {preview.rateLabel ? (
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

              {!previewBlocked && preview.metrics.length > 0 ? <ActionMetricsBlock rows={preview.metrics} /> : null}
            </>
          )}

          {showDeferredDetails && preview?.risk?.title && preview.risk.message ? (
            <ActionRiskBanner level={preview.risk.level} title={preview.risk.title} message={preview.risk.message} />
          ) : null}
        </div>
      ) : null}

      {preview && showHomeDetails && showDeferredDetails ? (
        <ActionCard>
          <ActionInfoRow label="Avana Platform Fee" value={preview.networkFeeLabel} tooltip="fee" />
        </ActionCard>
      ) : null}

      {outcome ? <ActionOutcomeBanner tone={outcome.tone} title={outcome.title} message={outcome.message} /> : null}

      {!outcome && showBlockedBanner && blockedReason ? (
        <ActionOutcomeBanner
          tone="error"
          title="Action unavailable"
          message={formatBlockedOutcomeMessage(blockedReason, balanceValue ?? preview?.balanceLabel)}
        />
      ) : null}

      {isConfigureVisibleStage(stage) ? (
        accessLabel && (homeLayout || singlePrimaryCta) ? (
          <Link
            href={TRANSACT_ACCESS_HREF}
            onClick={accessCta.onClick}
            className={primaryCtaClass({ className: "mt-1" })}
            data-testid="action-footer-primary"
          >
            {t(accessLabel)}
          </Link>
        ) : accessLabel ? (
          <ActionFooter
            primaryLabel={accessLabel}
            primaryHref={TRANSACT_ACCESS_HREF}
            onPrimary={accessCta.onClick}
            secondaryLabel={secondaryLabel}
            onSecondary={onSecondary}
            secondaryHref={secondaryHref}
            sticky
          />
        ) : homeLayout || singlePrimaryCta ? (
          <button
            type="button"
            onClick={handlePrimary}
            disabled={primaryDisabled}
            className={primaryCtaClass({
              disabled: primaryDisabled,
              pending: isPending,
              className: "mt-1",
            })}
            data-testid="action-footer-primary"
          >
            {isPending ? t("Processing…") : t(primaryLabel).replace("{symbol}", assetSymbol ?? "")}
          </button>
        ) : (
          <ActionFooter
            primaryLabel={primaryLabel}
            primaryLabelSymbol={assetSymbol}
            secondaryLabel={secondaryLabel}
            onPrimary={handlePrimary}
            onSecondary={onSecondary}
            secondaryHref={secondaryHref}
            primaryDisabled={primaryDisabled}
            primaryPending={isPending}
            sticky
          />
        )
      ) : null}

      {preview && walletStage && shouldShowWalletToast(walletStage) ? (
        <ActionWalletToast message={walletToastMessage(walletStage, preview.amountLabel)} />
      ) : null}
    </>
  )
}
