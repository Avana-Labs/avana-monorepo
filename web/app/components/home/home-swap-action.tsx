"use client"

import { DEFAULT_SELL_ASSET_ID } from "@/app/lib/swap-system/default-sell-asset"
import { actionErrorMessage } from "@/app/lib/action-system/blocked-reason"
import { useCallback, useEffect, useMemo, useState } from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { ActionTokenIcon } from "@/app/components/action-page/action-token-icon"
import { primaryCtaClass } from "@/app/components/action-page/action-cta"
import { SwapStyleField } from "@/app/components/action-page/swap-style-field"
import { ActionSessionLoading } from "@/app/components/action-page/action-session-loading"
import { useSwapSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TRANSACT_ACCESS_HREF, useTransactAccessCta } from "@/app/lib/transact-access"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { SWAP_ASSETS, SWAP_CHAIN_ID } from "@/app/lib/swap-system/catalog"
import { validateSwapInputAmount } from "@/app/lib/swap-system/eligibility"
import type { SwapQuote } from "@/app/lib/swap-system/quote-types"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"

const ActionReviewStage = dynamic(
  () => import("@/app/components/action-page/action-review-stage").then((mod) => mod.ActionReviewStage),
  { loading: ActionSessionLoading },
)

const ActionSuccessStage = dynamic(
  () => import("@/app/components/action-page/action-success-stage").then((mod) => mod.ActionSuccessStage),
  { loading: ActionSessionLoading },
)

const ActionProcessingStage = dynamic(
  () => import("@/app/components/action-page/action-processing-stage").then((mod) => mod.ActionProcessingStage),
  { loading: ActionSessionLoading },
)

const SwapAssetPickerDialog = dynamic(() =>
  import("@/app/swap/swap-asset-picker-dialog").then((mod) => mod.SwapAssetPickerDialog),
)

function formatAmount(value: number) {
  if (!Number.isFinite(value)) return "0"
  if (value === 0) return "0"
  if (value < 0.0001) return "<0.0001"
  return value.toLocaleString(undefined, { maximumFractionDigits: 6 })
}

export { DEFAULT_SELL_ASSET_ID } from "@/app/lib/swap-system/default-sell-asset"

export function HomeSwapAction() {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const swap = useSwapSessionContext()
  const swappableAssets = SWAP_ASSETS.filter((asset) => asset.isSwapEnabled && !asset.isLpToken)
  // Sell starts on ETH as a neutral base (guests see a 0 amount; connected wallets see their
  // ETH balance). Buy still starts empty so the user picks the destination.
  const [inputAssetId, setInputAssetId] = useState(DEFAULT_SELL_ASSET_ID)
  const [outputAssetId, setOutputAssetId] = useState("")
  const [amount, setAmount] = useState("")
  const slippageBps = 50
  const [quote, setQuote] = useState<SwapQuote | null>(null)
  const [quoteState, setQuoteState] = useState<"idle" | "loading" | "valid" | "error">("idle")
  const [quoteRetry, setQuoteRetry] = useState(0)
  const [pickerSide, setPickerSide] = useState<"input" | "output" | null>(null)
  const [stage, setStage] = useState<ActionStage>("configure")
  const [isPending, setIsPending] = useState(false)
  const [outcome, setOutcome] = useState<{ tone: "success" | "error"; message: string } | null>(null)
  const [reviewPreviewUi, setReviewPreviewUi] = useState<ActionPreviewUi | null>(null)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [acceptedPriceImpact, setAcceptedPriceImpact] = useState(false)
  const networkGuard = useActionNetworkGuard()

  const inputAsset = SWAP_ASSETS.find((asset) => asset.id === inputAssetId) ?? null
  const outputAsset = SWAP_ASSETS.find((asset) => asset.id === outputAssetId) ?? null
  const inputBalance = swap.walletBalances.find(
    (balance) => balance.assetId === inputAsset?.id && balance.sourceType === "wallet",
  )
  const inputBalanceLabel = inputAsset && inputBalance ? formatAmount(inputBalance.amount) : null
  const validation = useMemo(
    () =>
      inputBalance && inputAsset && outputAsset
        ? validateSwapInputAmount({
            amountText: amount,
            balance: inputBalance,
            context: { originProduct: "wallet", chainId: SWAP_CHAIN_ID, outputAssetId },
          })
        : ({ valid: false, reason: "unsupported_asset", amount: null, maxAmount: 0 } as const),
    [amount, inputAsset, inputBalance, outputAsset, outputAssetId],
  )
  const getQuote = swap.getQuote
  const getIndicativeQuote = swap.getIndicativeQuote

  useEffect(() => {
    // A fresh quote invalidates any prior high-impact acknowledgement.
    setAcceptedPriceImpact(false)
    if (!validation.valid || !inputAsset || !outputAsset) {
      setQuote(null)
      setQuoteState("idle")
      return
    }

    let cancelled = false
    const request = {
      chainId: SWAP_CHAIN_ID,
      inputAssetId,
      outputAssetId,
      inputAmount: validation.amount,
      slippageBps,
    }
    setQuote(null)
    setQuoteState("loading")

    // Update the Buy card from the local shared swap engine immediately. Convex remains
    // authoritative: review stays disabled until the server quote replaces this estimate.
    void getIndicativeQuote(request).then((indicativeQuote) => {
      if (!cancelled && indicativeQuote.status === "valid") setQuote(indicativeQuote)
    })

    const timeout = window.setTimeout(() => {
      void getQuote(request)
        .then((nextQuote) => {
          if (cancelled) return
          if (nextQuote.status === "valid") setQuote(nextQuote)
          setQuoteState(nextQuote.status === "valid" ? "valid" : "error")
        })
        .catch(() => {
          if (!cancelled) setQuoteState("error")
        })
    }, 250)

    return () => {
      cancelled = true
      window.clearTimeout(timeout)
    }
  }, [
    getIndicativeQuote,
    getQuote,
    inputAsset,
    inputAssetId,
    outputAsset,
    outputAssetId,
    quoteRetry,
    slippageBps,
    validation,
  ])

  useEffect(() => {
    setOutcome(null)
    if (stage === "review" || stage === "error") setStage("configure")
  }, [amount, inputAssetId, outputAssetId, slippageBps])

  const previewUi = useMemo<ActionPreviewUi | null>(() => {
    if (!quote || !validation.valid || !inputAsset || !outputAsset) return null
    const receiveLabel = `${formatAmount(quote.estimatedOutputAmount)} ${outputAsset.symbol}`
    const approvalRequired = swap.requiresApproval(inputAsset.id, validation.amount)

    return {
      allowed: true,
      quoteId: quote.id,
      amountLabel: `${amount} ${inputAsset.symbol}`,
      amountTitle: t("Sell"),
      amountValue: amount,
      assetLabel: inputAsset.symbol,
      assetSymbol: inputAsset.symbol,
      amountUsd: validation.amount * inputAsset.priceUsd,
      amountUsdLabel: exact(validation.amount * inputAsset.priceUsd),
      rateLabel: t("Rate"),
      rateValue: `1 ${inputAsset.symbol} = ${formatAmount(quote.exchangeRate)} ${outputAsset.symbol}`,
      marketLabel: t("Buy"),
      marketValue: receiveLabel,
      balanceLabel: t("Balance"),
      balanceValue: `${formatAmount(validation.maxAmount)} ${inputAsset.symbol}`,
      maxAmount: validation.maxAmount,
      metrics: [
        {
          id: "minimum-received",
          label: t("Minimum received"),
          value: `${formatAmount(quote.minimumOutputAmount)} ${outputAsset.symbol}`,
        },
        {
          id: "price-impact",
          label: t("Price impact"),
          value: `${quote.priceImpactPct.toFixed(2)}%`,
          tone: quote.priceImpactPct >= 3 ? "danger" : "default",
        },
        { id: "provider", label: t("Provider"), value: quote.provider },
      ],
      networkFeeLabel: exact(quote.networkFeeUsd),
      risk:
        quote.priceImpactPct >= 3
          ? {
              level: "danger",
              title: t("Large price difference"),
              message: t("You will receive significantly less than the current market value."),
            }
          : null,
      blockedReason: networkGuard.blockedReason,
      validationErrors: [],
      warnings: [],
      executionSteps: [
        ...(approvalRequired ? [{ id: "approve", label: `Approve ${inputAsset.symbol}` }] : []),
        { id: "sign", label: t("Confirm in wallet") },
        { id: "submit", label: t("Submit") },
      ],
    }
  }, [amount, exact, inputAsset, networkGuard.blockedReason, outputAsset, quote, swap, t, validation])

  const submitSwap = useCallback(async () => {
    if (!quote || !previewUi || !validation.valid || !inputAsset || !outputAsset || isPending) return
    // Safety parity with /swap: never submit on the wrong network, and require an
    // explicit acknowledgement for a high price-impact swap. (#24)
    if (networkGuard.isWrongNetwork) return
    if (quote.priceImpactPct >= 3 && !acceptedPriceImpact) return
    setIsPending(true)
    setOutcome(null)

    try {
      const { runActionSubmitFlow } = await import("@/app/lib/action-system/action-submit-runtime")
      const approvalRequired = swap.requiresApproval(inputAsset.id, validation.amount)
      const result = await runActionSubmitFlow({
        simulated: true,
        needsAllowance: approvalRequired,
        onStage: setStage,
        execute: async () => {
          if (approvalRequired) {
            const approval = await swap.approve(inputAsset.id, validation.amount)
            if (approval.status !== "approval_confirmed") {
              throw new Error(approval.failureReason ?? t("Approval failed."))
            }
          }
          const transaction = await swap.executeSwap(quote)
          return {
            transaction,
            receipt: {
              status: transaction.status === "confirmed" ? "success" : transaction.status,
              error: transaction.failureReason ?? null,
              hash: transaction.swapTransactionHash ?? null,
            },
          }
        },
      })
      const transaction = result.transaction
      if (transaction.status !== "confirmed") throw new Error(transaction.failureReason ?? t("Swap failed."))

      setSuccessUi({
        quoteId: quote.id,
        title: t("Swap successful."),
        description: `${amount} ${inputAsset.symbol} ${t("swapped for")} ${formatAmount(quote.estimatedOutputAmount)} ${outputAsset.symbol}.`,
        receiptHash: transaction.swapTransactionHash ?? null,
        metrics: previewUi.metrics,
        primaryCtaLabel: t("View wallet"),
        primaryCtaHref: "/dashboard?tab=wallet",
        secondaryCtaLabel: t("Swap again"),
        receiptContext: {
          verb: t("Sold"),
          amountUsd: validation.amount * inputAsset.priceUsd,
          amountLabel: `${amount} ${inputAsset.symbol}`,
          rateLabel: t("Received"),
          rateValue: `${formatAmount(quote.estimatedOutputAmount)} ${outputAsset.symbol}`,
          marketValue: quote.provider,
          // Carry the real quote fee so the inline receipt matches the estimate
          // and the permalink receipt instead of a hash-derived amount.
          networkFeeUsd: quote.networkFeeUsd,
        },
      })
      setStage("success")
    } catch (error) {
      setOutcome({ tone: "error", message: actionErrorMessage(error, t("Swap failed.")) })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [
    acceptedPriceImpact,
    amount,
    inputAsset,
    isPending,
    networkGuard.isWrongNetwork,
    outputAsset,
    previewUi,
    quote,
    swap,
    t,
    validation,
  ])

  const resetSwap = useCallback(() => {
    setInputAssetId("")
    setOutputAssetId("")
    setAmount("")
    setQuote(null)
    setReviewPreviewUi(null)
    setSuccessUi(null)
    setOutcome(null)
    setAcceptedPriceImpact(false)
    setStage("configure")
  }, [])

  // Guests keep the quote form but are sent to the dashboard onboarding instead of review.
  const accessCta = useTransactAccessCta()
  const accessLabel = accessCta.label

  // With Sell prefilled, ask for the Buy asset first: a wallet without ETH should see
  // "Select Asset", not "Insufficient balance", before it has picked anything.
  const primaryLabel = !outputAssetId
    ? "Select Asset"
    : !inputBalance
      ? inputAssetId
        ? "Insufficient balance"
        : "Select Asset"
      : !validation.valid
        ? validation.reason === "invalid_amount"
          ? "Enter an amount"
          : "Swap unavailable"
        : quoteState === "loading"
          ? "Loading quote"
          : quoteState === "error"
            ? "Refresh quote"
            : "Review swap"

  const isTransactionStage = [
    "approve_allowance",
    "wallet_sign",
    "processing",
    "submitted",
    "confirmed",
    "refreshing_position",
    "reconciled",
  ].includes(stage)

  return (
    <div className="space-y-3">
      {isTransactionStage ? (
        <ActionProcessingStage verb="Swap" preview={reviewPreviewUi ?? previewUi} onClose={resetSwap} stage={stage} />
      ) : null}

      {stage === "success" && successUi ? (
        <ActionSuccessStage success={successUi} onSecondary={resetSwap} secondaryLabel="Swap again" />
      ) : null}

      {stage === "review" && (reviewPreviewUi ?? previewUi) ? (
        <ActionReviewStage
          title={t("Review swap")}
          subtitle={t("Confirm the details below before signing.")}
          preview={(reviewPreviewUi ?? previewUi)!}
          primaryLabel={t("Swap")}
          onPrimary={() => void submitSwap()}
          onSecondary={() => setStage("configure")}
          primaryPending={isPending}
          hideHeader
          amountVariant="raised"
          confirmationGate={
            quote && quote.priceImpactPct >= 3
              ? {
                  checked: acceptedPriceImpact,
                  onCheckedChange: setAcceptedPriceImpact,
                  label: t("I understand this swap may result in a significant loss of value."),
                }
              : undefined
          }
        />
      ) : null}

      {stage === "configure" || stage === "error" ? (
        <>
          <div className="flex flex-col gap-1">
            <HomeSwapAssetField
              label={t("Sell")}
              amount={amount}
              onAmountChange={setAmount}
              assetId={inputAssetId}
              onOpenAssetPicker={() => setPickerSide("input")}
              fiatLabel={
                quote && outputAsset
                  ? exact(quote.estimatedOutputAmount * outputAsset.priceUsd)
                  : exact((Number(amount) || 0) * (inputAsset?.priceUsd ?? 0))
              }
              balanceLabel={inputBalanceLabel}
              onBalanceClick={
                inputBalance
                  ? () => {
                      setAmount(String(Math.floor(inputBalance.amount * 1e6) / 1e6))
                    }
                  : undefined
              }
              tone="raised"
            />
            <div>
              <HomeSwapAssetField
                label={t("Buy")}
                amount={quote ? formatAmount(quote.estimatedOutputAmount) : "0"}
                assetId={outputAssetId}
                onOpenAssetPicker={() => setPickerSide("output")}
                fiatLabel={quote && outputAsset ? exact(quote.estimatedOutputAmount * outputAsset.priceUsd) : exact(0)}
                readOnly
                tone="inset"
              />
            </div>
          </div>

          {outcome ? (
            <div className="rounded-radius-xl border border-danger/30 bg-danger/10 p-4 text-[14px] text-foreground">
              {outcome.message}
            </div>
          ) : null}

          {accessLabel ? (
            <Link
              href={TRANSACT_ACCESS_HREF}
              onClick={accessCta.onClick}
              className={primaryCtaClass({ className: "mt-1" })}
              data-testid="action-footer-primary"
            >
              {t(accessLabel)}
            </Link>
          ) : (
            <button
              type="button"
              disabled={
                !validation.valid || quoteState === "loading" || (!quote && quoteState !== "error") || isPending
              }
              onClick={() => {
                if (quoteState === "error") {
                  setQuoteRetry((current) => current + 1)
                  return
                }
                if (previewUi) {
                  setReviewPreviewUi(previewUi)
                  setStage("review")
                }
              }}
              className={primaryCtaClass({
                disabled: !validation.valid || quoteState === "loading" || (!quote && quoteState !== "error"),
                pending: isPending,
                className: "mt-1",
              })}
              data-testid="action-footer-primary"
            >
              {isPending ? t("Processing…") : t(primaryLabel)}
            </button>
          )}
        </>
      ) : null}

      {(stage === "configure" || stage === "error") && pickerSide !== null && (
        <SwapAssetPickerDialog
          open={pickerSide !== null}
          onOpenChange={(open) => {
            if (!open) setPickerSide(null)
          }}
          title={pickerSide === "input" ? "Sell" : "Buy"}
          assets={swappableAssets}
          balances={swap.walletBalances}
          selectedAssetId={pickerSide === "input" ? inputAssetId : outputAssetId}
          excludedAssetId={pickerSide === "input" ? outputAssetId : inputAssetId}
          onSelect={(assetId) => {
            if (pickerSide === "input") {
              setInputAssetId(assetId)
              if (assetId === outputAssetId) setOutputAssetId("")
            }
            if (pickerSide === "output") setOutputAssetId(assetId)
          }}
        />
      )}
    </div>
  )
}

function HomeSwapAssetField({
  label,
  amount,
  onAmountChange,
  assetId,
  onOpenAssetPicker,
  fiatLabel,
  balanceLabel,
  onBalanceClick,
  readOnly = false,
  tone,
}: {
  label: string
  amount: string
  onAmountChange?: (value: string) => void
  assetId: string
  onOpenAssetPicker: () => void
  fiatLabel: string
  balanceLabel?: string | null
  onBalanceClick?: () => void
  readOnly?: boolean
  tone: "raised" | "inset"
}) {
  const { t } = useTranslation()
  const asset = SWAP_ASSETS.find((item) => item.id === assetId) ?? null
  return (
    <SwapStyleField label={label} tone={tone} className="py-3">
      {/* Row sizing mirrors the shared ActionAmountCard (borrow/repay/claim/remove) exactly —
          no min-heights — so the Express Sell/Buy cards are the SAME height as the other tabs'
          cards and there's no card-size shift when switching tabs. (#9) */}
      <div className="mt-1.5 flex items-center justify-between gap-3 max-[360px]:flex-col max-[360px]:items-start">
        <div className="min-w-0 flex-1">
          <input
            value={amount}
            readOnly={readOnly}
            onChange={(event) => onAmountChange?.(event.target.value.replace(/[^\d.]/g, ""))}
            inputMode="decimal"
            // h-[1em] makes the <input> size to its line box exactly like the borrow tab's
            // amount <div>, so the Sell/Buy cards are the SAME height as the borrow cards and
            // there's no card-size shift when toggling Express tabs. (#9)
            className={`h-[1em] w-full min-w-0 border-0 bg-transparent p-0 text-[clamp(1.5rem,4vw,2rem)] font-normal leading-none tracking-[-0.02em] outline-none placeholder:text-muted-foreground/80 ${
              amount && amount !== "0" ? "text-foreground" : "text-muted-foreground/80"
            }`}
            placeholder="0"
            aria-label={label}
          />
        </div>
        <button
          type="button"
          onClick={onOpenAssetPicker}
          className="inline-flex h-11 shrink-0 items-center gap-2 rounded-full border border-border bg-surface-raised px-3 text-[14px] font-medium leading-5 text-foreground hover:bg-surface-hover max-[360px]:self-end"
        >
          {/* Accessible name = "Sell asset: <visible text>" so it contains what is on screen. */}
          <span className="sr-only">{`${label} asset: `}</span>
          {/* Fixed-geometry pill: a size-7 token icon fits inside the stable box so
              it never resizes between "Select Asset" and a picked asset. Mirrors the
              shared ActionAmountCard pill (ASSET_PILL_CLASS) so the box is identical
              across the homepage, action pages, and detail pages. */}
          <span className="inline-flex min-w-0 items-center gap-2">
            {asset ? (
              <>
                <ActionTokenIcon symbol={asset.symbol} size="pill" />
                <span className="truncate">{asset.symbol}</span>
              </>
            ) : (
              <span>{t("Select Asset")}</span>
            )}
          </span>
          <span aria-hidden className="shrink-0 text-muted-foreground">
            ▾
          </span>
        </button>
      </div>
      <div className="mt-1 flex items-center justify-between gap-3 text-[14px] leading-5">
        <span className="min-w-0 truncate text-foreground/60">{fiatLabel}</span>
        {balanceLabel ? (
          <button
            type="button"
            onClick={onBalanceClick}
            className="max-w-[12rem] shrink-0 truncate text-[13px] text-muted-foreground transition-colors hover:text-foreground"
          >
            Balance: <span className="text-foreground">{balanceLabel}</span>
          </button>
        ) : null}
      </div>
    </SwapStyleField>
  )
}
