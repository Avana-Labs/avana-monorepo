"use client"

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useAvanaIdentity, useLendSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { getWalletBalanceForLendMarket } from "@/app/lib/lend-system/wallet-balances"
import { getLendMarketById } from "@/app/lib/lend-system/catalog"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor, actionPagePath } from "@/app/lib/action-system/contracts"
import {
  mapLendDepositPreviewToActionUi,
  mapLendWithdrawPreviewToActionUi,
} from "@/app/lib/action-system/adapters/lend-preview-mapper"
import { mapBorrowSuccessToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage } from "@/app/components/action-page/action-configure-stage"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionSelectStage } from "@/app/components/action-page/action-select-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { lendDepositSelectItems, lendWithdrawSelectItems } from "@/app/lib/action-system/resolve-lend-context"
import { formatLendMarketDropdownSublabel, formatLendMarketValueLabel } from "@/app/lib/lend-system/market-labels"
import {
  formatActionAmount,
  formatActionFeeSummary,
  formatActionUsd,
  formatActionUsdBeforeAfter,
} from "@/app/lib/action-system/formatters"
import { isConfigureVisibleStage, isSubmittingStage, reviewStageTitle } from "@/app/lib/action-system/stage-machine"
import { parsePositiveActionAmount } from "@/app/lib/action-system/amount-input"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { actionErrorMessage } from "@/app/lib/action-system/blocked-reason"

export function lendSuccessMetrics(
  metrics: ActionPreviewUi["metrics"],
  kind: "deposit" | "withdraw",
  amount: number,
  symbol: string,
  now = Date.now(),
) {
  if (kind !== "withdraw") return metrics
  return metrics.map((metric) => {
    if (metric.id === "withdrawable-balance") {
      return { ...metric, label: "Wallet received", value: formatActionAmount(amount, symbol, 4) }
    }
    // The review ticks accrued earnings live; the receipt freezes them at submit time. It read
    // "$0.00 → $0.00" after the review showed "$0.30 → $0.28".
    if (metric.liveUsd) {
      const { anchorMs, before, after } = metric.liveUsd
      const years = anchorMs != null ? Math.max(0, now - anchorMs) / (365 * 24 * 3600 * 1000) : 0
      const beforeUsd = before.baseUsd + years * before.ratePerYearUsd
      const afterUsd = after.baseUsd + years * after.ratePerYearUsd
      return {
        ...metric,
        liveUsd: undefined,
        value: formatActionUsdBeforeAfter(beforeUsd, afterUsd),
        before: formatActionUsd(beforeUsd),
        after: formatActionUsd(afterUsd),
      }
    }
    return metric
  })
}

export function LendActionPageClient({
  kind,
  closeHref = "/lend",
  embedded = false,
  sidebar = false,
  layout = "default",
  initialAssetId,
  initialMarketId,
  initialAmount = "",
}: {
  kind: "deposit" | "withdraw"
  closeHref?: string
  embedded?: boolean
  sidebar?: boolean
  layout?: "default" | "home"
  initialAssetId?: string
  initialMarketId?: string
  initialAmount?: string
}) {
  const descriptor = getActionDescriptor("lend", kind)
  const router = useRouter()
  const { exact } = useCurrency()
  const { t } = useTranslation()
  const { walletId } = useAvanaIdentity()
  const session = useLendSessionContext()
  const priceFor = useCanonicalPriceFor()
  const depositItems = useMemo(
    () => (kind === "deposit" ? lendDepositSelectItems(session, walletId) : []),
    [kind, session, walletId],
  )
  const withdrawItems = useMemo(
    () => (kind === "withdraw" ? lendWithdrawSelectItems(session, walletId) : []),
    [kind, session, walletId],
  )
  // A lend market is "available" whenever it exists in the catalog or session. An
  // unknown initial id (stale link) is treated as "no initial market" so the user
  // lands on the picker instead of a "Market unavailable" dead-end.
  // A lend market is keyed by its asset id, so ?asset=usdc resolves the same as ?market=.
  // Prefer an explicit market id, then fall back to the asset id from the deep link.
  const requestedMarketId = initialMarketId ?? initialAssetId
  const validInitialMarketId =
    requestedMarketId && (session.state.markets[requestedMarketId] ?? getLendMarketById(requestedMarketId))
      ? requestedMarketId
      : undefined
  const hasInvalidInitialMarket = Boolean(requestedMarketId) && !validInitialMarketId
  const [marketId, setMarketId] = useState(() => validInitialMarketId ?? (kind === "deposit" ? "gho" : ""))
  const [stage, setStage] = useState<ActionStage>(() => {
    if (embedded) return "configure"
    if (hasInvalidInitialMarket) return "select"
    if (kind === "withdraw" && !validInitialMarketId) return "select"
    if (kind === "deposit" && !validInitialMarketId) return "select"
    return "configure"
  })
  const [amount, setAmount] = useState(initialAmount)
  // Input stays bound to `amount`; the engine preview below keys off the deferred value so
  // it runs on the settled input, not once per keystroke (the INP lever). See borrow client.
  const deferredAmount = useDeferredValue(amount)
  const [previewUi, setPreviewUi] = useState<ActionPreviewUi | null>(null)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [outcome, setOutcome] = useState<{ tone: "error" | "success"; title: string; message: string } | null>(null)
  // Wrong-network submit gate (read via ref inside handlePrimary; see borrow client).
  const networkGuard = useActionNetworkGuard()
  const networkGuardRef = useRef(networkGuard)
  networkGuardRef.current = networkGuard
  const [isPending, setIsPending] = useState(false)

  const market = useMemo(
    () => (marketId ? (session.state.markets[marketId] ?? getLendMarketById(marketId)) : null),
    [marketId, session.state.markets],
  )
  const assetPriceUsd = market ? (priceFor(market.asset.symbol) ?? market.assetPriceUsd) : 0

  const depositAssetOptions = useMemo(() => {
    if (kind !== "deposit") return undefined
    const options = Object.values(session.state.markets)
      .filter((entry) => getWalletBalanceForLendMarket(session.state, walletId, entry) > 0)
      .map((entry) => ({
        id: entry.marketId,
        label: entry.asset.symbol,
        symbol: entry.asset.symbol,
        sublabel: formatLendMarketDropdownSublabel(entry.asset.symbol),
      }))
    return options.length > 1 ? options : undefined
  }, [kind, session.state, walletId])

  useEffect(() => {
    if (embedded || kind !== "withdraw" || initialMarketId || marketId) return
    if (withdrawItems.length === 1) {
      router.replace(actionPagePath("lend", "withdraw", { market: withdrawItems[0]!.id }))
      return
    }
    if (withdrawItems.length > 1) setStage("select")
  }, [embedded, initialMarketId, kind, marketId, router, withdrawItems])

  useEffect(() => {
    if (embedded) return
    if (!validInitialMarketId) return
    setMarketId(validInitialMarketId)
    setStage("configure")
  }, [embedded, validInitialMarketId])

  const position = useMemo(
    () =>
      Object.values(session.state.positions).find(
        (entry) => entry.walletId === walletId && entry.marketId === market?.marketId && entry.status === "active",
      ),
    [market?.marketId, session.state.positions, walletId],
  )

  // The Convex ledger materializes earned interest lazily. Use the same supply-time anchor as
  // the dashboard's My Deposits counter so a fresh server snapshot does not render accrued
  // earnings as $0 until the next ledger write.
  const accrualSinceMs = useMemo(() => {
    const anchors = [
      position?.openedAt,
      ...session.transactionHistory
        .filter((entry) => {
          const kind = entry.kind as string
          const status = entry.status as string
          return (
            entry.marketId === market?.marketId &&
            (kind === "deposit" || kind === "supply") &&
            (status === "success" || status === "confirmed")
          )
        })
        .map((entry) => entry.timestamp),
    ].filter((value): value is number => typeof value === "number" && Number.isFinite(value) && value > 0)
    return anchors.length > 0 ? Math.min(...anchors) : null
  }, [market?.marketId, position?.openedAt, session.transactionHistory])

  useEffect(() => {
    if (!market) return
    let cancelled = false
    const parsed = parsePositiveActionAmount(deferredAmount)
    if (parsed == null) {
      setPreviewUi(null)
      return
    }

    if (kind === "withdraw" && !position) {
      setPreviewUi({
        allowed: false,
        amountLabel: `${parsed} ${market.asset.symbol}`,
        amountUsdLabel: exact(0),
        rateLabel: t("Withdrawal"),
        rateValue: "—",
        marketLabel: t("Market"),
        marketValue: formatLendMarketValueLabel(market.asset.symbol),
        balanceLabel: t("Deposited"),
        balanceValue: "0",
        maxAmount: 0,
        metrics: [],
        networkFeeLabel: formatActionFeeSummary(0, 0.03),
        risk: null,
        blockedReason: t("No deposited position found for this market."),
        validationErrors: [t("No deposited position found for this market.")],
        warnings: [],
      })
      return
    }

    const action =
      kind === "deposit"
        ? ({
            type: "deposit" as const,
            walletId,
            marketId: market.marketId,
            depositAmount: parsed,
            walletBalance: getWalletBalanceForLendMarket(session.state, walletId, market),
          } as const)
        : ({
            type: "withdraw" as const,
            walletId,
            marketId: market.marketId,
            positionId: position!.positionId,
            withdrawAmount: parsed,
          } as const)

    void session
      .previewTransaction(session.createIntent(action))
      .then((preview) => {
        if (cancelled) return
        if (kind === "deposit") {
          setPreviewUi(
            mapLendDepositPreviewToActionUi(preview, {
              symbol: market.asset.symbol,
              amount: parsed,
              marketLabel: formatLendMarketValueLabel(market.asset.symbol),
              balanceAmount: getWalletBalanceForLendMarket(session.state, walletId, market),
              rewardsApy: market.rewardsApy,
              assetPriceUsd,
            }),
          )
          return
        }
        setPreviewUi(
          mapLendWithdrawPreviewToActionUi(preview, {
            symbol: market.asset.symbol,
            amount: parsed,
            marketLabel: formatLendMarketValueLabel(market.asset.symbol),
            balanceAmount: position?.currentSuppliedAmount ?? 0,
            assetPriceUsd,
            poolAvailableLiquidity: market.availableLiquidity,
            accrualSinceMs,
            liveAccrual: true,
          }),
        )
      })
      .catch(() => {
        if (!cancelled) setPreviewUi(null)
      })
    return () => {
      cancelled = true
    }
  }, [accrualSinceMs, deferredAmount, assetPriceUsd, kind, market, position, session, walletId])

  useEffect(() => {
    // Editing inputs after a failed submit clears the stale error banner and returns to
    // configure so the CTA is actionable again instead of stuck showing the old error.
    setOutcome(null)
    setStage((prev) => (prev === "error" ? "configure" : prev))
  }, [amount, marketId])

  const canGoBackToSelect = useMemo(() => {
    if (embedded) return false
    if (initialMarketId) return false
    if (kind === "withdraw") return withdrawItems.length > 1
    if (kind === "deposit") return depositItems.length > 1
    return false
  }, [depositItems.length, embedded, initialMarketId, kind, withdrawItems.length])
  // Balance shown on the amount card (and the click-to-max source) — surfaced
  // directly so it's visible before any amount is typed, not only once a preview
  // exists. Deposit → wallet balance; withdraw → currently supplied.
  const spendableBalanceAmount = useMemo(() => {
    if (!market) return 0
    return kind === "deposit"
      ? getWalletBalanceForLendMarket(session.state, walletId, market)
      : (position?.currentSuppliedAmount ?? 0)
  }, [kind, market, position, session.state, walletId])
  const spendableBalanceLabel = kind === "deposit" ? "Balance" : "Deposited"
  const spendableBalanceValue = market ? formatActionAmount(spendableBalanceAmount, market.asset.symbol, 4) : undefined

  // Max fills the relevant balance: wallet balance for deposit, max withdrawable
  // for withdraw. previewUi.maxAmount is the capped figure once a preview exists;
  // fall back to the raw balance so Max works before an amount is entered.
  const handleMax = useCallback(() => {
    const max = previewUi?.maxAmount ?? spendableBalanceAmount
    if (max == null || max <= 0) return
    // Floor to 6 dp so the fill never rounds above the balance and trips "insufficient".
    setAmount(String(Math.floor(max * 1e6) / 1e6))
  }, [previewUi?.maxAmount, spendableBalanceAmount])

  const handleBack = useCallback(() => {
    if (stage === "review") {
      setStage("configure")
      setOutcome(null)
      return
    }
    if (stage === "configure" && canGoBackToSelect) {
      router.replace(actionPagePath("lend", kind))
      return
    }
    router.push(closeHref)
  }, [canGoBackToSelect, closeHref, kind, router, stage])

  const handlePrimary = useCallback(async () => {
    if (stage === "success") {
      router.push(successUi?.primaryCtaHref ?? dashboardHrefForProduct("lend"))
      return
    }
    if (stage === "configure") {
      if (!market || !previewUi?.allowed) return
      setStage("review")
      return
    }
    if (stage !== "review" && stage !== "error") return // allow in-place retry from error
    if (!market || !previewUi?.allowed) return
    if (isPending) return // guard against double-submit (rapid double-click)
    if (networkGuardRef.current.isWrongNetwork) {
      setOutcome({
        tone: "error",
        title: "Wrong network",
        message: networkGuardRef.current.blockedReason ?? "Switch networks to continue.",
      })
      return
    }

    setIsPending(true)
    setOutcome(null)

    try {
      const parsed = parsePositiveActionAmount(amount)
      if (parsed == null) throw new Error(t("Enter a valid amount"))
      const action =
        kind === "deposit"
          ? {
              type: "deposit" as const,
              walletId,
              marketId: market.marketId,
              depositAmount: parsed,
              walletBalance: getWalletBalanceForLendMarket(session.state, walletId, market),
            }
          : {
              type: "withdraw" as const,
              walletId,
              marketId: market.marketId,
              positionId: position!.positionId,
              withdrawAmount: parsed,
            }
      const intent = session.createIntent(action)
      const preview = await session.previewTransaction(intent)
      if (!preview.allowed) throw new Error(preview.validationErrors[0] ?? t("Action unavailable"))
      const executionPreviewUi =
        kind === "deposit"
          ? mapLendDepositPreviewToActionUi(preview, {
              symbol: market.asset.symbol,
              amount: parsed,
              marketLabel: formatLendMarketValueLabel(market.asset.symbol),
              balanceAmount: getWalletBalanceForLendMarket(session.state, walletId, market),
              rewardsApy: market.rewardsApy,
              assetPriceUsd,
            })
          : mapLendWithdrawPreviewToActionUi(preview, {
              symbol: market.asset.symbol,
              amount: parsed,
              marketLabel: formatLendMarketValueLabel(market.asset.symbol),
              balanceAmount: position?.currentSuppliedAmount ?? 0,
              assetPriceUsd,
              poolAvailableLiquidity: market.availableLiquidity,
              // Same accrual as the review, so the receipt does not drop to the un-accrued $0.
              accrualSinceMs,
              liveAccrual: true,
            })

      const simulated = session.readAdapter.mode === "sandbox"
      const result = await runActionSubmitFlow({
        simulated,
        needsAllowance: kind === "deposit",
        onStage: setStage,
        execute: async () => session.executeTransaction(preview.intent),
      })

      if (result.receipt.status !== "success") throw new Error(result.receipt.error ?? t("Transaction failed"))
      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: `${descriptor.primaryVerb} successful`,
          description: `${parsed.toFixed(4)} ${market.asset.symbol} processed.`,
          receiptHash: result.receipt.hash ?? null,
          metrics: lendSuccessMetrics(executionPreviewUi.metrics, kind, parsed, market.asset.symbol),
          href: dashboardHrefForProduct("lend"),
          primaryCtaLabel: successDashboardCtaLabel("lend"),
          preview: executionPreviewUi,
          verb: descriptor.primaryVerb,
        }),
      )
      setStage("success")
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : t("Unable to sign the transaction")
      // Raw backend codes stay in logs; users see plain-language copy (issue #143).
      if (process.env.NODE_ENV !== "production") console.error(rawMessage)
      setOutcome({
        tone: "error",
        title: t("Something went wrong"),
        message: actionErrorMessage(error, t("Unable to sign the transaction")),
      })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [
    amount,
    closeHref,
    descriptor.primaryVerb,
    exact,
    isPending,
    kind,
    market,
    position,
    previewUi,
    router,
    session,
    stage,
    successUi,
    t,
    walletId,
  ])

  if (shouldShowActionSessionLoading(session.isHydrated)) {
    return (
      <ActionPageShell
        title={descriptor.title}
        subtitle={descriptor.subtitle}
        closeHref={closeHref}
        mode={embedded ? "embedded" : "page"}
        density={sidebar ? "sidebar" : "default"}
        hideTitle={embedded || sidebar}
        hideClose={embedded}
        flowHeaderStage={!embedded ? stage : undefined}
      >
        <ActionSessionLoading />
      </ActionPageShell>
    )
  }

  // Never dead-end on "Market unavailable": an unknown id routes to the picker
  // (stage "select") above. This only guards the impossible no-market/non-select
  // case and renders nothing rather than an error card.
  if (!market && stage !== "select") return null

  const hideTitle = embedded || stage === "success" || isSubmittingStage(stage) || stage === "review"
  const isHomeLayout = embedded && layout === "home"
  const shellSubtitle =
    stage === "select" && kind === "withdraw"
      ? t("Choose the market to withdraw from.")
      : stage === "select" && kind === "deposit"
        ? t("Choose the asset to deposit.")
        : stage === "success" || isSubmittingStage(stage) || stage === "review"
          ? undefined
          : descriptor.subtitle

  return (
    <ActionPageShell
      mode={embedded ? "embedded" : "page"}
      density={sidebar ? "sidebar" : isHomeLayout ? "home" : "default"}
      title={descriptor.title}
      subtitle={shellSubtitle}
      hideTitle={hideTitle}
      hideClose={embedded}
      closeHref={closeHref}
      flowHeaderStage={!embedded ? stage : undefined}
    >
      {stage === "select" && !embedded ? (
        <ActionSelectStage
          items={kind === "withdraw" ? withdrawItems : depositItems}
          sectionLabel={kind === "withdraw" ? t("Your positions") : t("Supported assets")}
          searchPlaceholder={kind === "withdraw" ? t("Find an asset") : t("Search assets")}
          emptyTitle={kind === "withdraw" ? t("No deposits found") : t("No assets in your wallet")}
          emptyDescription={
            kind === "withdraw"
              ? t("Deposit first, then withdraw from here.")
              : t("You need to hold a supported asset in your wallet before you can deposit.")
          }
          onSelect={(id) => {
            router.replace(actionPagePath("lend", kind, { market: id }))
          }}
        />
      ) : null}

      {isSubmittingStage(stage) ? (
        <ActionProcessingStage verb={descriptor.primaryVerb} preview={previewUi} closeHref={closeHref} stage={stage} />
      ) : null}

      {stage === "review" && previewUi ? (
        <ActionReviewStage
          title={reviewStageTitle(descriptor.primaryVerb)}
          subtitle={t("Confirm the details below before signing.")}
          preview={previewUi}
          primaryLabel={descriptor.primaryVerb}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          primaryPending={isPending}
          blockedReason={networkGuard.blockedReason}
        />
      ) : null}

      {stage === "success" && successUi ? <ActionSuccessStage success={successUi} closeHref={closeHref} /> : null}

      {isConfigureVisibleStage(stage) && market ? (
        <ActionConfigureStage
          stage={stage === "error" ? "configure" : stage}
          verb={descriptor.primaryVerb}
          amount={amount}
          onAmountChange={setAmount}
          preview={previewUi}
          emptyReason={kind === "withdraw" && withdrawItems.length === 0 ? "Nothing to withdraw" : undefined}
          assetSymbol={market.asset.symbol}
          assetOptions={depositAssetOptions}
          selectedAssetId={market.marketId}
          onAssetSelect={(id) => {
            setMarketId(id)
            setAmount("")
          }}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          secondaryHref={canGoBackToSelect ? undefined : closeHref}
          canGoBack={canGoBackToSelect}
          isPending={isPending}
          outcome={outcome}
          homeLayout={isHomeLayout}
          singlePrimaryCta={sidebar}
          hideAssetSelector={isHomeLayout && Boolean(initialMarketId)}
          showBalance
          balanceLabel={spendableBalanceLabel}
          balanceValue={spendableBalanceValue}
          onMax={handleMax}
        />
      ) : null}
    </ActionPageShell>
  )
}
