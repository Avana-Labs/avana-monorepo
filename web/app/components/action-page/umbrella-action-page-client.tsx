"use client"

import { actionErrorMessage } from "@/app/lib/action-system/blocked-reason"
import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor } from "@/app/lib/action-system/contracts"
import { formatActionFeeSummary } from "@/app/lib/action-system/formatters"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { isConfigureVisibleStage, isSubmittingStage, reviewStageTitle } from "@/app/lib/action-system/stage-machine"
import { parsePositiveActionAmount } from "@/app/lib/action-system/amount-input"
import { formatUsdExact } from "@/app/lib/borrow-sim"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage } from "@/app/components/action-page/action-configure-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"
import { useUmbrellaSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { UmbrellaMarketRiskMetricsCard } from "@/app/umbrella/_detail/market-sections/UmbrellaStress"
import { useCanonicalPriceFor, usePriceFor, usePriceFreshness } from "@/app/lib/prices/token-prices-context"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"

type UmbrellaActionKind = "stake" | "claim" | "cooldown" | "unstake"

// Currency-aware: matches the header currency switcher like every other surface
// (previously hardcoded "$", leaving the Umbrella action page in USD under EUR/etc.).
function formatUsd(value: number) {
  return formatUsdExact(value)
}

function formatUnits(value: number) {
  return value.toLocaleString("en-US", { maximumFractionDigits: Number.isInteger(value) ? 0 : 4 })
}

function formatDurationShort(ms: number): string {
  if (ms <= 0) return "0h"
  const totalHours = Math.max(1, Math.ceil(ms / (60 * 60 * 1000)))
  const days = Math.floor(totalHours / 24)
  const hours = totalHours % 24
  if (days <= 0) return `${hours}h`
  return `${days}d ${hours}h`
}

function previewFor({
  kind,
  amount,
  marketId,
  umbrella,
  livePriceUsd,
  priceUnavailable,
  now,
}: {
  kind: UmbrellaActionKind
  amount: number
  marketId: UmbrellaMarketId
  umbrella: ReturnType<typeof useUmbrellaSessionContext>
  livePriceUsd: number
  priceUnavailable: boolean
  now: number
}): ActionPreviewUi {
  const market = umbrella.markets[marketId]
  const position = umbrella.positions[marketId]
  const walletBalance = umbrella.walletBalances[marketId] ?? 0
  const activeStake = Math.max(0, position.amount - position.cooldownAmount)
  const cooldownActive = position.cooldownAmount > 0 && position.cooldownStatus !== "expired"
  const maxAmount =
    kind === "stake"
      ? walletBalance
      : kind === "cooldown"
        ? activeStake
        : kind === "unstake"
          ? position.cooldownAmount
          : null
  const amountUsd = kind === "claim" ? position.pendingRewardsUsd : amount * livePriceUsd
  const blockedReason =
    kind !== "claim" && priceUnavailable
      ? `Current Convex price unavailable for ${market.symbol}`
      : kind === "stake" && amount > walletBalance
        ? `Insufficient ${market.symbol} balance`
        : kind === "cooldown" && amount > activeStake
          ? `Insufficient active ${market.symbol}`
          : kind === "cooldown" && cooldownActive
            ? "Finish or unstake the current cooldown before starting a new one."
            : kind === "unstake" && amount > position.cooldownAmount
              ? `Insufficient cooled ${market.symbol}`
              : kind === "unstake" && (position.cooldownStatus === "expired" || position.withdrawalWindowExpired)
                ? "Withdrawal window expired — restart cooldown."
                : kind === "unstake" && position.cooldownStatus !== "ready"
                  ? "Cooldown is not ready"
                  : kind === "claim" && position.pendingRewardsUsd <= 0
                    ? "No Umbrella rewards to claim"
                    : null
  const allowed = kind === "claim" ? !blockedReason : amount > 0 && !blockedReason
  const verb =
    kind === "cooldown" ? "Start cooldown" : kind === "unstake" ? "Unstake" : kind === "claim" ? "Claim" : "Stake"

  const warnings: string[] = []
  if (kind === "unstake") {
    if (
      position.cooldownStatus === "ready" &&
      typeof position.withdrawalWindowEndsAt === "number" &&
      position.withdrawalWindowEndsAt > now
    ) {
      warnings.push(`Withdrawal window: ${formatDurationShort(position.withdrawalWindowEndsAt - now)} left`)
    } else if (
      position.cooldownStatus === "cooling" &&
      typeof position.cooldownEndsAt === "number" &&
      position.cooldownEndsAt > now
    ) {
      warnings.push(`Cooldown ends in ${formatDurationShort(position.cooldownEndsAt - now)}`)
    } else {
      warnings.push("Withdrawal only succeeds during the open withdrawal window.")
    }
  }

  const metrics: ActionPreviewUi["metrics"] = [
    { id: "coverage", label: "Coverage", value: market.coverage },
    { id: "total-staked", label: "Market staked", value: formatUsd(market.totalStakedUsd) },
    ...(kind === "cooldown"
      ? [
          { id: "cooldown", label: "Cooldown", value: "20 days" },
          { id: "withdrawal-window", label: "Withdrawal window", value: "2 days" },
        ]
      : []),
    ...(kind === "stake" && position.amount > 0
      ? [
          {
            id: "current-stake",
            label: "Current stake",
            value: `${formatUnits(position.amount)} ${market.symbol}`,
          },
          ...(amount > 0
            ? [
                {
                  id: "new-total",
                  label: "New total",
                  value: `${formatUnits(position.amount + amount)} ${market.symbol}`,
                },
              ]
            : []),
        ]
      : []),
  ]

  return {
    allowed,
    // Claim label is always USD; success-screen receiptContext reuses this via preview.amountLabel.
    amountLabel: kind === "claim" ? formatUsd(position.pendingRewardsUsd) : `${formatUnits(amount)} ${market.symbol}`,
    amountUsd,
    amountUsdLabel: formatUsd(amountUsd),
    rateLabel: kind === "claim" ? "Claim total" : "Umbrella APY",
    rateValue: kind === "claim" ? formatUsd(position.pendingRewardsUsd) : `${market.apy.toFixed(2)}%`,
    marketLabel: "Umbrella market",
    marketValue: market.asset,
    balanceLabel:
      kind === "stake"
        ? "Wallet balance"
        : kind === "cooldown"
          ? "Active stake"
          : kind === "claim"
            ? "Pending rewards"
            : "Cooled stake",
    balanceValue:
      kind === "stake"
        ? `${formatUnits(walletBalance)} ${market.symbol}`
        : kind === "cooldown"
          ? `${formatUnits(activeStake)} ${market.symbol}`
          : kind === "claim"
            ? formatUsd(position.pendingRewardsUsd)
            : `${formatUnits(position.cooldownAmount)} ${market.symbol}`,
    maxAmount,
    assetSymbol: market.symbol,
    metrics,
    networkFeeLabel: formatActionFeeSummary(amountUsd),
    risk:
      kind === "stake" || kind === "cooldown"
        ? {
            level: "warning",
            title: "Slashable stake",
            message: "Umbrella stake remains slashable while active and during cooldown.",
          }
        : null,
    blockedReason,
    validationErrors: blockedReason ? [blockedReason] : [],
    warnings,
    amountTitle: verb,
  }
}

export function UmbrellaActionPageClient({
  kind,
  closeHref = "/umbrella",
  initialMarketId,
  initialAmount = "",
  embedded = false,
  sidebar = false,
  onMarketChange,
}: {
  kind: UmbrellaActionKind
  closeHref?: string
  initialMarketId?: string
  initialAmount?: string
  embedded?: boolean
  sidebar?: boolean
  onMarketChange?: (marketId: UmbrellaMarketId) => void
}) {
  const descriptor = getActionDescriptor("umbrella", kind)
  const router = useRouter()
  const umbrella = useUmbrellaSessionContext()
  const livePriceFor = usePriceFor()
  const priceFreshness = usePriceFreshness()
  const priceFor = useCanonicalPriceFor()
  const [marketId, setMarketId] = useState<UmbrellaMarketId>(
    initialMarketId && umbrella.marketOrder.includes(initialMarketId as UmbrellaMarketId)
      ? (initialMarketId as UmbrellaMarketId)
      : "gho",
  )
  const [amount, setAmount] = useState(initialAmount)
  const [stage, setStage] = useState<ActionStage>("configure")
  const [isPending, setIsPending] = useState(false)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [outcome, setOutcome] = useState<{ tone: "error"; title: string; message: string } | null>(null)
  // Wrong-network submit gate (read via ref inside submit; mirrors lend/borrow).
  const networkGuard = useActionNetworkGuard()
  const networkGuardRef = useRef(networkGuard)
  networkGuardRef.current = networkGuard
  const market = umbrella.markets[marketId]
  const position = umbrella.positions[marketId]
  // Reset amount + stage when the sidebar swaps `kind` (Stake↔Cooldown↔Unstake↔Claim).
  // Lets UmbrellaSidebar drop its `key={tab}` remount hack (Fix #34) so React can
  // reuse the tree — cheaper, no picker/animation flash — while the input still
  // clears between tabs. Claim seeds pending rewards; other kinds start empty.
  useEffect(() => {
    setAmount(kind === "claim" ? String(position.pendingRewardsUsd) : "")
    setStage("configure")
    setOutcome(null)
    setSuccessUi(null)
    // Intentionally only depends on `kind`: switching markets already re-seeds via
    // the picker's onAssetSelect handler; positions refresh must not clobber user input.
  }, [kind])
  // Deferred so the preview runs on the settled input, not once per keystroke (INP lever).
  const deferredAmount = useDeferredValue(amount)
  const parsedAmount = parsePositiveActionAmount(deferredAmount) ?? 0
  const strictLivePriceUsd = livePriceFor(market.symbol)
  const priceUnavailable = priceFreshness.stale || strictLivePriceUsd === undefined
  const livePriceUsd = strictLivePriceUsd ?? priceFor(market.symbol) ?? market.priceUsd
  const preview = useMemo(
    () =>
      previewFor({
        kind,
        amount: parsedAmount,
        marketId,
        umbrella,
        livePriceUsd,
        priceUnavailable,
        now: Date.now(),
      }),
    [kind, marketId, parsedAmount, umbrella, livePriceUsd, priceUnavailable],
  )
  const assetOptions = umbrella.marketOrder.map((id) => ({
    id,
    label: umbrella.markets[id].symbol,
    symbol: umbrella.markets[id].symbol,
    sublabel: `${umbrella.markets[id].apy.toFixed(2)}% APY`,
  }))

  const submit = async () => {
    if (stage === "success") {
      router.push(successUi?.primaryCtaHref ?? dashboardHrefForProduct("umbrella"))
      return
    }
    if (stage === "configure") {
      if (!preview.allowed) return
      setStage("review")
      return
    }
    if (stage !== "review" || isPending || !preview.allowed) return
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
      const result = await runActionSubmitFlow({
        simulated: true,
        needsAllowance: kind === "stake",
        onStage: setStage,
        execute: async () => {
          const tx: { status: "success" | "failed"; hash: string } =
            kind === "stake"
              ? await umbrella.stake(marketId, parsedAmount)
              : kind === "claim"
                ? await umbrella.claim(marketId)
                : kind === "cooldown"
                  ? await umbrella.startCooldown(marketId, parsedAmount)
                  : await umbrella.unstake(marketId, parsedAmount)
          return { receipt: { status: tx.status, hash: tx.hash } }
        },
      })
      if (result.receipt.status !== "success") throw new Error("Transaction failed")
      // "Stake more" — surface a distinct success verb when the user added to an
      // existing position instead of opening a fresh one. Keeps the descriptor
      // constants untouched (all four kinds still funnel through one action page).
      const isStakeMore = kind === "stake" && position.amount > 0
      const successVerb = isStakeMore ? "Stake more" : descriptor.primaryVerb
      // Claim-rewards upsell — when a stake / stake-more / cooldown succeeds and
      // the user still has pending rewards, route the secondary CTA to /actions/
      // umbrella/claim instead of dumping them back on the landing page. Keeps
      // the "Back to Umbrella" fallback for actions where nothing else is queued.
      const nextPendingRewardsUsd = umbrella.positions[marketId].pendingRewardsUsd
      const shouldUpsellClaim = (kind === "stake" || kind === "cooldown") && nextPendingRewardsUsd > 0
      setSuccessUi({
        title: `${successVerb} successful`,
        description: `${preview.amountLabel} processed in ${market.asset}.`,
        receiptHash: result.receipt.hash ?? null,
        metrics: preview.metrics,
        primaryCtaLabel: shouldUpsellClaim ? "Claim rewards" : successDashboardCtaLabel("umbrella"),
        primaryCtaHref: shouldUpsellClaim
          ? `/actions/umbrella/claim?market=${marketId}&return=${encodeURIComponent(closeHref)}`
          : dashboardHrefForProduct("umbrella"),
        secondaryCtaLabel: "Back to Umbrella",
        receiptContext: {
          verb: successVerb,
          amountUsd: preview.amountUsd,
          amountLabel: preview.amountLabel,
          rateLabel: preview.rateLabel,
          rateValue: preview.rateValue,
          marketValue: preview.marketValue,
        },
      })
      setStage("success")
    } catch (error) {
      const message = actionErrorMessage(error, "Umbrella action failed")
      setOutcome({ tone: "error", title: "Something went wrong", message })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }

  const back = () => {
    if (stage === "review" || stage === "error") {
      setStage("configure")
      return
    }
    router.push(closeHref)
  }

  const hideTitle = embedded || stage === "success" || isSubmittingStage(stage) || stage === "review"
  const amountReadOnly = kind === "claim"

  if (shouldShowActionSessionLoading(umbrella.isHydrated)) {
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

  // "Stake more" verb variant when the user already holds this market — the
  // descriptor stays generic; we swap the visible verb so review/processing/CTA
  // read correctly for top-ups.
  const dynamicVerb = kind === "stake" && position.amount > 0 ? "Stake more" : descriptor.primaryVerb

  // Immediate (non-deferred) amount the configure stage sees. Drives the
  // configure stage's deferred risk-banner and network-fee gating.
  // Claim amount is the fixed pending-rewards total (read-only). Round to 4dp and
  // drop trailing zeros so it reads cleanly (e.g. "20.6007", not "20.6006661022")
  // while staying comma-free so the configure stage can still parse it.
  const stageAmount = kind === "claim" ? String(Number(position.pendingRewardsUsd.toFixed(4))) : amount
  const enteredAmount = parsePositiveActionAmount(stageAmount)
  const hasAmountEntered = enteredAmount != null
  const estimatedAnnualRewardsUsd =
    kind === "stake" && enteredAmount != null ? enteredAmount * livePriceUsd * (market.apy / 100) : undefined
  const earnedRewardsUsd = kind === "stake" ? undefined : position.pendingRewardsUsd

  return (
    <ActionPageShell
      title={kind === "stake" && position.amount > 0 ? "Stake more" : descriptor.title}
      subtitle={hideTitle ? undefined : descriptor.subtitle}
      hideTitle={hideTitle}
      closeHref={closeHref}
      mode={embedded ? "embedded" : "page"}
      density={sidebar ? "sidebar" : "default"}
      hideClose={embedded}
      flowHeaderStage={!embedded ? stage : undefined}
    >
      {isSubmittingStage(stage) ? (
        <ActionProcessingStage verb={dynamicVerb} preview={preview} closeHref={closeHref} stage={stage} />
      ) : null}
      {stage === "review" ? (
        <ActionReviewStage
          title={reviewStageTitle(dynamicVerb)}
          subtitle="Confirm the details below before signing."
          preview={preview}
          primaryLabel={dynamicVerb}
          onPrimary={() => void submit()}
          onSecondary={back}
          primaryPending={isPending}
          blockedReason={networkGuard.blockedReason}
        />
      ) : null}
      {stage === "success" && successUi ? <ActionSuccessStage success={successUi} closeHref={closeHref} /> : null}
      {isConfigureVisibleStage(stage) ? (
        <ActionConfigureStage
          stage={stage === "error" ? "configure" : stage}
          verb={dynamicVerb}
          amount={stageAmount}
          onAmountChange={setAmount}
          preview={preview}
          assetSymbol={market.symbol}
          assetOptions={assetOptions}
          selectedAssetId={marketId}
          onAssetSelect={(id) => {
            const next = id as UmbrellaMarketId
            setMarketId(next)
            setAmount("")
            onMarketChange?.(next)
          }}
          onPrimary={() => void submit()}
          onSecondary={back}
          secondaryHref={closeHref}
          isPending={isPending}
          outcome={outcome}
          amountReadOnly={amountReadOnly}
          showBalance
          balanceLabel={preview.balanceLabel}
          balanceValue={preview.balanceValue}
          onMax={() => {
            if (preview.maxAmount != null) setAmount(String(preview.maxAmount))
          }}
          singlePrimaryCta={sidebar}
          detailsSlot={
            <UmbrellaMarketRiskMetricsCard
              market={market}
              showExpandedDetails={hasAmountEntered}
              estimatedAnnualRewardsUsd={estimatedAnnualRewardsUsd}
              earnedRewardsUsd={earnedRewardsUsd}
            />
          }
          deferDetailsUntilAmount
          animateDetails={false}
          allowAssetSwitchWhenReadOnly
        />
      ) : null}
    </ActionPageShell>
  )
}
