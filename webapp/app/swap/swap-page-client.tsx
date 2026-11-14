"use client"

import { DEFAULT_SELL_ASSET_ID } from "@/app/lib/swap-system/default-sell-asset"
import { TRANSACT_ACCESS_HREF, useTransactAccessCta } from "@/app/lib/transact-access"
import dynamic from "next/dynamic"

import { useCallback, useEffect, useMemo, useState } from "react"
import { SwapAssetIcon } from "@/app/swap/swap-asset-icon"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionSessionLoading } from "@/app/components/action-page/action-session-loading"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { SwapStyleField } from "@/app/components/action-page/swap-style-field"
import { ActionFooter } from "@/app/components/action-page/action-amount-card"
import {
  NATIVE_GAS_RESERVE_ETH,
  SWAP_ASSETS,
  SWAP_CHAIN_ID,
  getMaxSwapInputAmount,
  validateSwapInputAmount,
  type SwapRestrictionReason,
} from "@/app/lib/swap-system"
import { useSwapSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import type { SwapQuote } from "@/app/lib/swap-system"

const ActionReviewStage = dynamic(
  () => import("@/app/components/action-page/action-review-stage").then((mod) => mod.ActionReviewStage),
  { loading: ActionSessionLoading },
)

const ActionSuccessStage = dynamic(
  () => import("@/app/components/action-page/action-success-stage").then((mod) => mod.ActionSuccessStage),
  { loading: ActionSessionLoading },
)

const SwapAssetPickerDialog = dynamic(() =>
  import("./swap-asset-picker-dialog").then((mod) => mod.SwapAssetPickerDialog),
)

type SwapPageClientProps = {
  initialFrom?: string
  initialTo?: string
  origin?: string
  returnHref?: string
}

function fallbackOutput(inputAssetId: string) {
  return inputAssetId === "usdc" ? "eth" : "usdc"
}

function formatAmount(value: number) {
  if (!Number.isFinite(value)) return "0"
  if (value === 0) return "0"
  if (value < 0.0001) return "<0.0001"
  return value.toLocaleString(undefined, { maximumFractionDigits: 6 })
}

function swapValidationMessage(reason: SwapRestrictionReason, asset: (typeof SWAP_ASSETS)[number]) {
  switch (reason) {
    case "invalid_amount":
      return `Enter a valid ${asset.symbol} amount.`
    case "below_minimum":
      return `Minimum swap is ${asset.minimumSwapAmount.toLocaleString(undefined, { maximumFractionDigits: 8 })} ${asset.symbol}.`
    case "above_maximum":
      return `Maximum swap is ${formatAmount(asset.maximumSwapAmount)} ${asset.symbol}.`
    case "insufficient_native_gas":
      return `Keep at least ${formatAmount(NATIVE_GAS_RESERVE_ETH)} ETH for network fees.`
    case "insufficient_balance":
      return `Insufficient ${asset.symbol} balance.`
    case "same_asset":
      return "Choose a different asset to buy."
    case "unsupported_pair":
      return "This asset pair is not available. Choose a different asset."
    case "ineligible_deposited":
      return `${asset.symbol} is deposited in Lend and cannot be swapped from this wallet flow.`
    case "ineligible_pledged":
      return `${asset.symbol} is pledged as collateral and cannot be swapped from this wallet flow.`
    case "ineligible_protocol_locked":
      return `${asset.symbol} is locked by the protocol and cannot be swapped here.`
    case "ineligible_lp_token":
    case "unsupported_asset":
      return `${asset.symbol} is not available for swapping.`
  }
}

export function SwapPageClient({ initialFrom, initialTo, origin = "wallet", returnHref = "/" }: SwapPageClientProps) {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const swap = useSwapSessionContext()
  const networkGuard = useActionNetworkGuard()
  const canonicalPriceFor = useCanonicalPriceFor()
  const swappableAssets = SWAP_ASSETS.filter((asset) => asset.isSwapEnabled && !asset.isLpToken)
  // Sell starts on ETH like the homepage swap; Buy stays empty until the user picks it.
  const [inputAssetId, setInputAssetId] = useState(initialFrom ?? DEFAULT_SELL_ASSET_ID)
  const [outputAssetId, setOutputAssetId] = useState(
    initialTo && initialTo !== initialFrom ? initialTo : initialFrom ? fallbackOutput(initialFrom) : "",
  )
  const [amount, setAmount] = useState("")
  const slippageBps = 50
  const [quote, setQuote] = useState<SwapQuote | null>(null)
  const [quoteState, setQuoteState] = useState<"idle" | "loading" | "valid" | "error">("idle")
  const [quoteRetry, setQuoteRetry] = useState(0)
  const [stage, setStage] = useState<ActionStage>("configure")
  const [isPending, setIsPending] = useState(false)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [pickerSide, setPickerSide] = useState<"input" | "output" | null>(null)
  const [acceptedPriceImpact, setAcceptedPriceImpact] = useState(false)
  const [outcome, setOutcome] = useState<{ tone: "success" | "error"; message: string } | null>(null)

  const inputAsset = SWAP_ASSETS.find((asset) => asset.id === inputAssetId)
  const outputAsset = SWAP_ASSETS.find((asset) => asset.id === outputAssetId)
  const inputPriceUsd = inputAsset ? (canonicalPriceFor(inputAsset.symbol) ?? inputAsset.priceUsd) : 0
  const outputPriceUsd = outputAsset ? (canonicalPriceFor(outputAsset.symbol) ?? outputAsset.priceUsd) : 0
  const inputBalance = inputAsset
    ? swap.walletBalances.find((balance) => balance.assetId === inputAsset.id && balance.sourceType === "wallet")
    : undefined
  const maxAmount = inputBalance
    ? getMaxSwapInputAmount(inputBalance, { originProduct: "wallet", chainId: SWAP_CHAIN_ID, outputAssetId })
    : 0
  const validation = useMemo(
    () =>
      inputBalance
        ? validateSwapInputAmount({
            amountText: amount,
            balance: inputBalance,
            context: { originProduct: "wallet", chainId: SWAP_CHAIN_ID, outputAssetId },
          })
        : ({ valid: false, reason: "insufficient_balance", amount: null, maxAmount: 0 } as const),
    [amount, inputBalance, outputAssetId],
  )
  const approvalRequired =
    validation.valid && inputAsset ? swap.requiresApproval(inputAsset.id, validation.amount) : false
  const getQuote = swap.getQuote
  useEffect(() => {
    if (!inputAssetId || !outputAssetId || !validation.valid) {
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
  }, [getQuote, inputAssetId, outputAssetId, quoteRetry, slippageBps, validation])

  useEffect(() => {
    setOutcome(null)
    setAcceptedPriceImpact(false)
    setStage((current) => (current === "error" ? "configure" : current))
  }, [amount, inputAssetId, outputAssetId, slippageBps])

  const previewUi = useMemo<ActionPreviewUi | null>(() => {
    if (!quote || !validation.valid || !inputAsset || !outputAsset) return null
    const receiveLabel = `${formatAmount(quote.estimatedOutputAmount)} ${outputAsset.symbol}`
    return {
      allowed: true,
      quoteId: quote.id,
      amountLabel: `${amount} ${inputAsset.symbol}`,
      amountTitle: t("Sell"),
      amountValue: amount,
      assetLabel: inputAsset.symbol,
      assetSymbol: inputAsset.symbol,
      // Review's Sell notional is the gross input value. Fees and price impact are
      // represented by the separate received/minimum-received quote values.
      amountUsd: validation.amount * inputPriceUsd,
      amountUsdLabel: exact(validation.amount * inputPriceUsd),
      rateLabel: t("Rate"),
      rateValue: `1 ${inputAsset.symbol} = ${formatAmount(quote.exchangeRate)} ${outputAsset.symbol}`,
      marketLabel: t("Buy"),
      marketValue: receiveLabel,
      balanceLabel: t("Balance"),
      balanceValue: `${formatAmount(maxAmount)} ${inputAsset.symbol}`,
      maxAmount,
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
      // Keep the surfaced steps terse and standard — the same short vocabulary the
      // other actions use — and drop the internal "refresh balances" step, which no
      // other action exposes. (#39)
      executionSteps: [
        ...(approvalRequired ? [{ id: "approve", label: `Approve ${inputAsset.symbol}` }] : []),
        { id: "sign", label: t("Confirm in wallet") },
        { id: "submit", label: t("Submit") },
      ],
    }
  }, [
    amount,
    approvalRequired,
    exact,
    inputAsset,
    maxAmount,
    networkGuard.blockedReason,
    outputAsset,
    outputPriceUsd,
    quote,
    t,
    validation,
  ])

  const submitSwap = useCallback(async () => {
    if (!quote || !previewUi || !validation.valid || !inputAsset || !outputAsset || isPending) return
    if (networkGuard.isWrongNetwork) return
    if (quote.priceImpactPct >= 3 && !acceptedPriceImpact) return
    setIsPending(true)
    setOutcome(null)
    try {
      let executionQuote = quote
      if (Date.now() >= quote.expiresAt) {
        const refreshedQuote = await getQuote({
          chainId: SWAP_CHAIN_ID,
          inputAssetId,
          outputAssetId,
          inputAmount: validation.amount,
          slippageBps,
        })
        if (refreshedQuote.status !== "valid") throw new Error(t("Unable to refresh the expired quote."))
        const outputChanged =
          Math.abs(refreshedQuote.estimatedOutputAmount - quote.estimatedOutputAmount) /
            Math.max(quote.estimatedOutputAmount, Number.EPSILON) >
          0.005
        setQuote(refreshedQuote)
        executionQuote = refreshedQuote
        if (outputChanged) {
          setOutcome({ tone: "error", message: t("The quote changed. Review the updated amount before continuing.") })
          setStage("configure")
          return
        }
      }
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
          const transaction = await swap.executeSwap(executionQuote)
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
      if (result.receipt.status !== "success") throw new Error(result.receipt.error ?? t("Swap failed."))
      setSuccessUi({
        quoteId: executionQuote.id,
        title: t("Swap successful."),
        description: `${amount} ${inputAsset.symbol} ${t("swapped for")} ${formatAmount(executionQuote.estimatedOutputAmount)} ${outputAsset.symbol}.`,
        receiptHash: result.receipt.hash,
        metrics: previewUi.metrics,
        primaryCtaLabel: t("View wallet"),
        primaryCtaHref: "/dashboard?tab=wallet",
        secondaryCtaLabel: t("Swap again"),
        receiptContext: {
          verb: t("Sold"),
          amountUsd: validation.amount * inputPriceUsd,
          amountLabel: `${amount} ${inputAsset.symbol}`,
          rateLabel: t("Received"),
          rateValue: `${formatAmount(executionQuote.estimatedOutputAmount)} ${outputAsset.symbol}`,
          marketValue: executionQuote.provider,
          // Carry the real quote fee so the inline receipt matches the estimate
          // and the permalink receipt instead of a hash-derived amount.
          networkFeeUsd: executionQuote.networkFeeUsd,
        },
      })
      setStage("success")
    } catch (error) {
      setOutcome({ tone: "error", message: error instanceof Error ? error.message : t("Swap failed.") })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [
    acceptedPriceImpact,
    amount,
    approvalRequired,
    getQuote,
    inputAsset,
    inputAssetId,
    inputPriceUsd,
    isPending,
    outputAsset,
    outputAssetId,
    previewUi,
    quote,
    slippageBps,
    swap,
    t,
    validation,
    networkGuard.isWrongNetwork,
  ])

  const resetSwap = useCallback(() => {
    setAmount("")
    setQuote(null)
    setSuccessUi(null)
    setOutcome(null)
    setStage("configure")
  }, [])

  const accessCta = useTransactAccessCta()
  const accessLabel = accessCta.label
  const primaryLabel =
    !inputAsset || !outputAsset
      ? "Select assets"
      : !inputBalance
        ? "Insufficient balance"
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
    <ActionPageShell
      title="Swap"
      subtitle={`Choose which assets to swap on Ethereum${origin !== "wallet" ? ` · ${origin}` : ""}`}
      closeHref={returnHref}
      flowHeaderStage={stage}
      flowHeaderHasSelectStep={false}
      hideTitle={stage === "review" || stage === "success" || isTransactionStage}
    >
      {isTransactionStage ? (
        <ActionProcessingStage verb="Swap" preview={previewUi} closeHref={returnHref} stage={stage} />
      ) : null}

      {stage === "success" && successUi ? (
        <ActionSuccessStage success={successUi} closeHref={returnHref} onSecondary={resetSwap} />
      ) : null}

      {stage === "review" && previewUi ? (
        <ActionReviewStage
          title={t("Review swap")}
          subtitle={t("Confirm the details below before signing.")}
          preview={previewUi}
          primaryLabel={t("Swap")}
          onPrimary={() => void submitSwap()}
          onSecondary={() => setStage("configure")}
          primaryPending={isPending}
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
        <div className="space-y-4">
          <div className="flex flex-col gap-1">
            <SwapAssetField
              label={t("Sell")}
              amount={amount}
              onAmountChange={setAmount}
              assetId={inputAssetId}
              onOpenAssetPicker={() => setPickerSide("input")}
              fiatLabel={exact((Number(amount) || 0) * inputPriceUsd)}
              balanceLabel={formatAmount(maxAmount)}
              onBalanceClick={() => setAmount(String(Math.floor(maxAmount * 1e6) / 1e6))}
              tone="raised"
            />

            <SwapAssetField
              label={t("Buy")}
              amount={quote ? formatAmount(quote.estimatedOutputAmount) : "0"}
              readOnly
              assetId={outputAssetId}
              onOpenAssetPicker={() => setPickerSide("output")}
              fiatLabel={quote ? exact(quote.estimatedOutputAmount * outputPriceUsd) : exact(0)}
              tone="inset"
            />
          </div>
          {amount.trim() && inputAsset && !validation.valid && validation.reason ? (
            <div
              className="rounded-radius-lg border border-danger/30 bg-danger/10 px-4 py-3 text-[14px] text-foreground"
              data-testid="swap-validation-message"
            >
              {swapValidationMessage(validation.reason, inputAsset)}
            </div>
          ) : null}
          {outcome ? (
            <div
              className={`rounded-radius-xl border p-4 text-[14px] ${
                outcome.tone === "success"
                  ? "border-brand/30 bg-brand/10 text-foreground"
                  : "border-danger/30 bg-danger/10 text-foreground"
              }`}
            >
              {outcome.message}
            </div>
          ) : null}
          {/* A guest saw a disabled "Select assets" with no way forward; match the configure stage. */}
          {accessLabel ? (
            <ActionFooter
              primaryLabel={t(accessLabel)}
              primaryHref={TRANSACT_ACCESS_HREF}
              onPrimary={accessCta.onClick}
              secondaryHref={returnHref}
              sticky
            />
          ) : (
            <ActionFooter
              primaryLabel={primaryLabel}
              secondaryHref={returnHref}
              primaryDisabled={
                Boolean(networkGuard.blockedReason) ||
                !validation.valid ||
                quoteState === "loading" ||
                (!quote && quoteState !== "error")
              }
              onPrimary={() => {
                if (quoteState === "error") {
                  setQuoteRetry((current) => current + 1)
                  return
                }
                if (previewUi) setStage("review")
              }}
              sticky
            />
          )}
        </div>
      ) : null}

      {pickerSide !== null ? (
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
            if (pickerSide === "input") setInputAssetId(assetId)
            if (pickerSide === "output") setOutputAssetId(assetId)
          }}
        />
      ) : null}
    </ActionPageShell>
  )
}

function SwapAssetField({
  label,
  amount,
  onAmountChange,
  assetId,
  onOpenAssetPicker,
  balanceLabel,
  onBalanceClick,
  fiatLabel,
  tone,
  readOnly = false,
}: {
  label: string
  amount: string
  onAmountChange?: (value: string) => void
  assetId?: string
  onOpenAssetPicker: () => void
  balanceLabel?: string
  onBalanceClick?: () => void
  fiatLabel: string
  tone: "raised" | "inset"
  readOnly?: boolean
}) {
  const asset = SWAP_ASSETS.find((item) => item.id === assetId)
  return (
    <SwapStyleField label={label} tone={tone} className="py-3">
      <div className="mt-1.5 flex min-h-10 items-center justify-between gap-3 max-[360px]:flex-col max-[360px]:items-stretch">
        <div className="min-w-0 flex-1">
          <input
            value={amount}
            readOnly={readOnly}
            onChange={(event) => onAmountChange?.(event.target.value.replace(/[^\d.]/g, ""))}
            inputMode="decimal"
            className={`w-full min-w-0 border-0 bg-transparent p-0 text-[clamp(1.5rem,4vw,2rem)] font-medium leading-none tracking-[-0.04em] outline-none placeholder:text-muted-foreground/80 ${
              amount && amount !== "0" ? "text-foreground" : "text-muted-foreground/80"
            }`}
            placeholder="0"
            aria-label={label}
          />
        </div>
        <button
          type="button"
          onClick={onOpenAssetPicker}
          className="inline-flex h-11 shrink-0 items-center gap-2 rounded-full border border-border bg-surface-raised px-3 text-[14px] font-medium text-foreground hover:bg-surface-hover max-[360px]:self-end"
        >
          {/* Accessible name = "Sell asset: <visible text>" so it contains what is on screen. */}
          <span className="sr-only">{`${label} asset: `}</span>
          {asset ? (
            <span className="inline-flex min-w-0 items-center gap-2">
              <SwapAssetIcon asset={asset} size="pill" />
              <span className="truncate">{asset.symbol}</span>
            </span>
          ) : (
            <span className="truncate text-muted-foreground">Select asset</span>
          )}
          <span aria-hidden className="shrink-0 text-muted-foreground">
            ▾
          </span>
        </button>
      </div>
      <div className="mt-1 flex min-h-5 items-center justify-between gap-3 text-[14px]">
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
