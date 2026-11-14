"use client"

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import { useAvanaIdentity, useMultiplySessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor } from "@/app/lib/action-system/contracts"
import {
  mapClosePreviewToActionUi,
  mapDeleveragePreviewToActionUi,
  mapMultiplyPreviewToActionUi,
} from "@/app/lib/action-system/adapters/multiply-preview-mapper"
import { translateMultiplyLoopMarketLabel } from "@/app/lib/multiply-system/market-labels"
import { mapBorrowSuccessToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage, ActionConfigureAmountSection } from "@/app/components/action-page/action-configure-stage"
import { ActionLeverageRuler } from "@/app/components/action-page/action-leverage-ruler"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { isConfigureVisibleStage, isSubmittingStage, reviewStageTitle } from "@/app/lib/action-system/stage-machine"
import { parsePositiveActionAmount } from "@/app/lib/action-system/amount-input"
import {
  MULTIPLY_ACTION_MIN_LEVERAGE,
  MULTIPLY_ACTION_SLIDER_MAX,
  MULTIPLY_ACTION_SLIDER_STEP,
  getDeleverageMultiplierMax,
  getDefaultDeleverageMultiplier,
  isDeleverageCloseOnly,
  resolveDefaultMultiplyLeverage,
  snapMultiplierToStep,
} from "@/app/lib/multiply-system/leverage-limits"
import {
  buildMultiplyOverCapPreviewUi,
  exceedsMultiplyCollateralCap,
  maxMultiplyCollateralAmount,
  resolveMultiplyCollateralPriceUsd,
} from "@/app/lib/multiply-system/collateral-limits"
import { formatActionAmount, formatActionUsd } from "@/app/lib/action-system/formatters"
import { useCanonicalPriceFor, usePriceFor, usePriceFreshness } from "@/app/lib/prices/token-prices-context"
import { actionErrorMessage } from "@/app/lib/action-system/blocked-reason"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export function MultiplyActionPageClient({
  kind,
  closeHref = "/multiply",
  embedded = false,
  sidebar = false,
  layout = "default",
  initialMarketId,
  initialAmount = "",
  initialMultiplier,
}: {
  kind: "multiply" | "deleverage" | "close"
  closeHref?: string
  embedded?: boolean
  sidebar?: boolean
  layout?: "default" | "home"
  initialMarketId?: string
  initialAmount?: string
  initialMultiplier?: string
}) {
  const descriptor = getActionDescriptor("multiply", kind)
  const { t } = useTranslation()
  const router = useRouter()
  const { walletId } = useAvanaIdentity()
  const session = useMultiplySessionContext()
  const livePriceFor = usePriceFor()
  const priceFreshness = usePriceFreshness()
  const isExitKind = kind === "deleverage" || kind === "close"
  const priceFor = useCanonicalPriceFor()
  const walletPositions = useMemo(
    () =>
      Object.values(session.state.positions).filter(
        (entry) => entry.walletId === walletId && (entry.collateralValueUsd > 0 || entry.debtValueUsd > 0),
      ),
    [session.state.positions, walletId],
  )
  // Only honor an initial market id that actually exists in the catalog. An unknown
  // id (stale link) is treated as "no initial market" so the picker shows instead of
  // dead-ending — every multiply market is available.
  const validInitialMarketId = initialMarketId && session.state.markets[initialMarketId] ? initialMarketId : undefined
  const [selectedMarketId, setSelectedMarketId] = useState<string | undefined>(
    () => validInitialMarketId ?? (isExitKind ? walletPositions[0]?.marketId : undefined),
  )
  const market = useMemo(() => {
    const markets = Object.values(session.state.markets)
    const selected = selectedMarketId ? (markets.find((entry) => entry.id === selectedMarketId) ?? null) : null
    // Never dead-end: fall back to the first catalog market (the picker lets the
    // user switch). market is null only if the catalog itself is empty.
    return selected ?? markets[0] ?? null
  }, [selectedMarketId, session.state.markets])

  // Opening a loop can target any market in the catalog; CLOSING or DELEVERAGING can only
  // target a market this wallet actually holds a position in. Scoping the exit picker to
  // those positions means every option leads somewhere — previously the exit routes hid the
  // selector entirely, so a market with no position (e.g. an already-closed wsteth-eth) was a
  // dead end reading "No open position to close in this market" with no way to switch.
  const marketOptions = useMemo(() => {
    const entries = isExitKind
      ? walletPositions
          .map((entry) => session.state.markets[entry.marketId])
          .filter((entry): entry is NonNullable<typeof entry> => Boolean(entry))
      : Object.values(session.state.markets)
    const seen = new Set<string>()
    const options = entries
      .filter((entry) => !seen.has(entry.id) && seen.add(entry.id))
      .map((entry) => ({
        id: entry.id,
        label: translateMultiplyLoopMarketLabel(t, entry.collateralAsset.symbol, entry.borrowAsset.symbol),
        symbol: entry.collateralAsset.symbol,
        borrowSymbol: entry.borrowAsset.symbol,
      }))
    // Exit kinds keep a single option visible so the user can always see WHICH position they
    // are about to close; opening only shows the picker when there is a real choice.
    if (options.length === 0) return undefined
    return isExitKind || options.length > 1 ? options : undefined
  }, [isExitKind, session.state.markets, t, walletPositions])
  // Value the collateral at the live oracle price when it is usable, else the catalog price
  // — the SAME guard the engine applies to the exposure. `??` alone passed a 0/NaN oracle
  // reading through and zeroed the displayed collateral USD while the exposure stayed at the
  // catalog price ("$0 under the field vs ~$525 exposure"). (E5)
  const liveCollateralPriceUsd = market ? livePriceFor(market.collateralAsset.symbol) : undefined
  const collateralPriceStale = priceFreshness.stale || liveCollateralPriceUsd === undefined
  const collateralPriceUsd = market
    ? resolveMultiplyCollateralPriceUsd(priceFor(market.collateralAsset.symbol), market.collateralAsset.priceUsd)
    : 0
  const walletCollateralBudgetUsd = market ? (session.state.walletBalancesUsd?.[walletId]?.[market.id] ?? 0) : 0
  // Cap a multiply position at the wallet's spendable balance (not the pool's
  // multi-million liquidity), still bounded by what the market can absorb. This
  // keeps Max affordable and rejects absurd inputs before the simulation engine.
  const maxCollateralAmount =
    kind === "multiply" && market
      ? maxMultiplyCollateralAmount(
          market.economics.availableLiquidityUsd,
          collateralPriceUsd,
          walletCollateralBudgetUsd,
        )
      : null

  const multiplierMin = MULTIPLY_ACTION_MIN_LEVERAGE
  const position = useMemo(() => {
    // Resolve against whichever market is SELECTED. The exit routes used to stay unbound
    // unless the caller supplied `initialMarketId`, which meant the standalone
    // /actions/multiply/close and /deleverage routes could never resolve a position even
    // though they auto-select one below. The collateral picker now makes the selection
    // explicit and visible, so binding to it is safe (and the review step restates it).
    if (!market) return null
    return walletPositions.find((entry) => entry.marketId === market.id) ?? null
  }, [market, walletPositions])
  const defaultMultiplyMultiplier = useMemo(() => {
    if (kind !== "multiply") return ""
    const safeDefault = market
      ? resolveDefaultMultiplyLeverage(market.risk.publicMaxMultiplier, market.risk.recommendedMaxMultiplier)
      : 1.1
    return String(Number(safeDefault.toFixed(2)))
  }, [kind, market])

  const [stage, setStage] = useState<ActionStage>("configure")
  const [amount, setAmount] = useState(initialAmount)
  // Input stays bound to `amount`; the engine preview below keys off the deferred value so
  // it runs on the settled input, not once per keystroke (the INP lever). See borrow client.
  const deferredAmount = useDeferredValue(amount)
  const [multiplier, setMultiplier] = useState(() =>
    kind === "close" ? "1" : (initialMultiplier ?? (kind === "deleverage" ? "" : defaultMultiplyMultiplier)),
  )
  const displayMultiplier = kind === "deleverage" && parsePositiveActionAmount(multiplier) == null ? "1" : multiplier
  const [hasUserInput, setHasUserInput] = useState(() => Boolean(initialAmount || initialMultiplier))

  useEffect(() => {
    if (!isExitKind || walletPositions.length === 0) return
    // Land on a market this wallet can actually exit. The selected market (from `?market=`,
    // a detail sidebar, or a previous pick) wins whenever it holds a position; otherwise fall
    // back to the first one that does, rather than dead-ending on "No open position". The
    // picker shows which market resolved, so the substitution is never hidden.
    const active = selectedMarketId ?? validInitialMarketId
    if (active && walletPositions.some((entry) => entry.marketId === active)) return
    setSelectedMarketId(walletPositions[0]!.marketId)
  }, [isExitKind, selectedMarketId, validInitialMarketId, walletPositions])

  useEffect(() => {
    if (kind !== "deleverage" || !position) return
    // Seed the default target ONCE per position (deps deliberately exclude `multiplier`).
    // Bail if a value already exists — an explicit initial value or one the user has
    // dragged to wins, so the slider stays user-controlled across [min, current] instead
    // of snapping back to the default on every change.
    if (parsePositiveActionAmount(multiplier) != null) return
    setMultiplier(initialMultiplier ?? getDefaultDeleverageMultiplier(position.multiplier))
  }, [initialMultiplier, kind, position?.id])

  useEffect(() => {
    setHasUserInput(Boolean(initialAmount || initialMultiplier))
  }, [initialAmount, initialMultiplier, kind, market?.id])

  useEffect(() => {
    // executeTransaction updates the shared session while the action is processing. Do not
    // clear/recompute the preview during that lifecycle; it makes the health-factor bar
    // oscillate and makes the action look like it refreshed underneath the user.
    if (stage !== "configure" && stage !== "review" && stage !== "error") return undefined
    if (!market) return
    const parsed = parsePositiveActionAmount(multiplier)
    if (parsed == null) return
    const effectiveMax =
      kind === "deleverage"
        ? getDeleverageMultiplierMax(position?.multiplier ?? Number.NaN, 0.1)
        : MULTIPLY_ACTION_SLIDER_MAX
    // Snap the canonical multiplier to the SAME step grid the ruler thumb uses, and
    // clamp to [min, max]. Binding the state to the slider's grid keeps the pill and the
    // projection summary on one value instead of drifting apart. (E6)
    // Multiply uses the global 1–9.99 / 0.01 slider; per-market publicMax is enforced by
    // engine validation (hard block), not by clamping the thumb.
    const step = kind === "deleverage" ? 0.1 : MULTIPLY_ACTION_SLIDER_STEP
    const next = String(snapMultiplierToStep(parsed, multiplierMin, effectiveMax, step))
    if (next !== multiplier) setMultiplier(next)
  }, [kind, market, multiplier, multiplierMin, position?.multiplier])
  const [previewUi, setPreviewUi] = useState<ActionPreviewUi | null>(null)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [outcome, setOutcome] = useState<{ tone: "error" | "success"; title: string; message: string } | null>(null)
  // Wrong-network submit gate (read via ref inside the submit handlers; see borrow client).
  const networkGuard = useActionNetworkGuard()
  const networkGuardRef = useRef(networkGuard)
  networkGuardRef.current = networkGuard
  const [isPending, setIsPending] = useState(false)

  useEffect(() => {
    if (!market) return
    let cancelled = false

    if (kind === "close") {
      if (!position) {
        const noPositionReason = "No open position to close in this market."
        setPreviewUi({
          allowed: false,
          amountLabel: "Full close",
          amountValue: "Full close",
          amountUsdLabel: "$0",
          rateLabel: "Final withdrawal",
          rateValue: "—",
          marketLabel: translateMultiplyLoopMarketLabel(t, market.collateralAsset.symbol, market.borrowAsset.symbol),
          marketValue: market.id,
          balanceLabel: "Position",
          balanceValue: "None",
          maxAmount: null,
          metrics: [],
          networkFeeLabel: "—",
          risk: null,
          blockedReason: noPositionReason,
          validationErrors: [noPositionReason],
          warnings: [],
        })
        return
      }
      const intent = session.createIntent({
        type: "close",
        walletId,
        positionId: position.id,
        collateralPriceUsd,
      })
      void session
        .previewTransaction(intent)
        .then((preview) => {
          if (cancelled) return
          setPreviewUi(
            mapClosePreviewToActionUi(preview, {
              marketLabel: translateMultiplyLoopMarketLabel(
                t,
                market.collateralAsset.symbol,
                market.borrowAsset.symbol,
              ),
              collateralSymbol: market.collateralAsset.symbol,
              liveCollateralValueUsd: position.collateralAmount * collateralPriceUsd,
            }),
          )
        })
        .catch(() => {
          if (!cancelled) setPreviewUi(null)
        })
      return () => {
        cancelled = true
      }
    }
    const parsedAmount = parsePositiveActionAmount(deferredAmount)
    const parsedMultiplier = parsePositiveActionAmount(
      kind === "deleverage" && parsePositiveActionAmount(multiplier) == null ? "1" : multiplier,
    )
    if (parsedMultiplier == null) {
      setPreviewUi(null)
      return
    }

    if (kind === "deleverage" && !position) {
      setPreviewUi({
        allowed: false,
        amountLabel: "0",
        amountUsdLabel: "$0",
        rateLabel: "Net APY",
        rateValue: "—",
        marketLabel: translateMultiplyLoopMarketLabel(t, market.collateralAsset.symbol, market.borrowAsset.symbol),
        marketValue: market.id,
        balanceLabel: "Position",
        balanceValue: "None",
        maxAmount: null,
        metrics: [],
        networkFeeLabel: "—",
        risk: null,
        blockedReason: "No open position to deleverage in this market.",
        validationErrors: ["No open position to deleverage in this market."],
        warnings: [],
      })
      return
    }

    // Deleverage intentionally shows no projection until the user picks a target leverage —
    // the seeded default is a starting point, not a recommendation. (The Collateral row's USD
    // comes from `amountUsdLabel`, not the preview, so it stays correct while this is blank.)
    if (kind === "deleverage" && !hasUserInput) {
      setPreviewUi(null)
      return
    }

    const multiplyCollateralAmount = kind === "multiply" ? parsedAmount : null
    if (kind === "multiply") {
      if (multiplyCollateralAmount == null) {
        setPreviewUi(null)
        return
      }

      if (exceedsMultiplyCollateralCap(multiplyCollateralAmount, maxCollateralAmount)) {
        setPreviewUi(
          buildMultiplyOverCapPreviewUi({
            collateralSymbol: market.collateralAsset.symbol,
            borrowSymbol: market.borrowAsset.symbol,
            collateralAmount: multiplyCollateralAmount,
            collateralPriceUsd,
            marketLabel: translateMultiplyLoopMarketLabel(t, market.collateralAsset.symbol, market.borrowAsset.symbol),
            multiplier: parsedMultiplier,
            maxCollateralAmount: maxCollateralAmount!,
          }),
        )
        return
      }

      const action = {
        type: "multiply" as const,
        walletId,
        marketId: market.id,
        collateralAmount: multiplyCollateralAmount,
        selectedMultiplier: parsedMultiplier,
        collateralPriceUsd,
        collateralPriceStale,
      }

      setPreviewUi(null)
      void session
        .previewTransaction(session.createIntent(action))
        .then((preview) => {
          if (cancelled) return
          setPreviewUi(
            mapMultiplyPreviewToActionUi(preview, {
              collateralSymbol: market.collateralAsset.symbol,
              borrowSymbol: market.borrowAsset.symbol,
              collateralAmount: multiplyCollateralAmount,
              collateralPriceUsd,
              // The engine now values the position at the same live price (threaded via
              // action.collateralPriceUsd), so the simulation figures are already live-
              // priced — no further display rescale (scale === 1). This keeps the preview
              // exactly equal to the persisted/dashboard position.
              catalogCollateralPriceUsd: collateralPriceUsd,
              marketLabel: translateMultiplyLoopMarketLabel(
                t,
                market.collateralAsset.symbol,
                market.borrowAsset.symbol,
              ),
              // Feed economics.supplyApy into the preview engine (not seed collateralAsset.apy)
              // so Net APY stays aligned after Convex hydration updates rates. (E4)
              collateralApy: market.economics.supplyApy,
              borrowApy: market.borrowAsset.borrowApy,
              multiplier: parsedMultiplier,
              maxLtv: market.risk.maxLtv,
            }),
          )
        })
        .catch(() => {
          if (!cancelled) setPreviewUi(null)
        })
      return () => {
        cancelled = true
      }
    }

    if (!position) {
      setPreviewUi(null)
      return
    }

    const action = {
      type: "deleverage" as const,
      walletId,
      positionId: position.id,
      targetMultiplier: parsedMultiplier,
      collateralPriceUsd,
    }

    void session
      .previewTransaction(session.createIntent(action))
      .then((preview) => {
        if (cancelled) return
        setPreviewUi(
          mapDeleveragePreviewToActionUi(preview, {
            marketLabel: translateMultiplyLoopMarketLabel(t, market.collateralAsset.symbol, market.borrowAsset.symbol),
            targetMultiplier: parsedMultiplier,
            collateralSymbol: market.collateralAsset.symbol,
          }),
        )
      })
      .catch(() => {
        if (!cancelled) setPreviewUi(null)
      })
    return () => {
      cancelled = true
    }
  }, [
    collateralPriceStale,
    collateralPriceUsd,
    deferredAmount,
    kind,
    market,
    maxCollateralAmount,
    multiplier,
    position,
    session,
    stage,
    walletId,
  ])

  useEffect(() => {
    // Editing inputs after a failed submit clears the stale error banner and returns to
    // configure so the CTA is actionable again instead of stuck showing the old error.
    setOutcome(null)
    setStage((prev) => (prev === "error" ? "configure" : prev))
  }, [amount, kind, market?.id, multiplier])

  const handleBack = useCallback(() => {
    if (stage === "review") {
      setStage("configure")
      setOutcome(null)
      return
    }
    router.push(closeHref)
  }, [closeHref, router, stage])

  // Fill the collateral input with the max affordable amount. Floor to 6 decimals
  // (not round) so the filled value can never round *up* past the cap and trip the
  // over-cap guard — a real risk now that the cap is the smaller wallet balance.
  const handleMaxCollateral = useCallback(() => {
    if (maxCollateralAmount == null || maxCollateralAmount <= 0) return
    setHasUserInput(true)
    setAmount(String(Math.floor(maxCollateralAmount * 1e6) / 1e6))
  }, [maxCollateralAmount])

  const handlePrimary = useCallback(async () => {
    if (stage === "success") {
      router.push(successUi?.primaryCtaHref ?? dashboardHrefForProduct("multiply"))
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
      const parsedAmount = parsePositiveActionAmount(amount)
      const parsedMultiplier = parsePositiveActionAmount(multiplier)
      if ((kind === "multiply" && parsedAmount == null) || (kind !== "close" && parsedMultiplier == null)) {
        throw new Error("Enter a valid amount")
      }
      const position = walletPositions.find((entry) => entry.marketId === market.id)
      if (isExitKind && !position) throw new Error("No position selected")

      const action =
        kind === "multiply"
          ? {
              type: "multiply" as const,
              walletId,
              marketId: market.id,
              collateralAmount: parsedAmount!,
              selectedMultiplier: parsedMultiplier!,
              collateralPriceUsd,
              collateralPriceStale,
            }
          : kind === "close"
            ? {
                type: "close" as const,
                walletId,
                positionId: position!.id,
                collateralPriceUsd,
              }
            : {
                type: "deleverage" as const,
                walletId,
                positionId: position!.id,
                targetMultiplier: parsedMultiplier!,
                collateralPriceUsd,
              }

      const intent = session.createIntent(action)
      const preview = await session.previewTransaction(intent)
      if (!preview.allowed) throw new Error(preview.validationErrors[0] ?? "Action unavailable")
      const marketLabel = translateMultiplyLoopMarketLabel(t, market.collateralAsset.symbol, market.borrowAsset.symbol)
      const executionPreviewUi =
        kind === "multiply"
          ? mapMultiplyPreviewToActionUi(preview, {
              marketLabel,
              collateralSymbol: market.collateralAsset.symbol,
              borrowSymbol: market.borrowAsset.symbol,
              collateralAmount: parsedAmount!,
              collateralPriceUsd,
              catalogCollateralPriceUsd: collateralPriceUsd,
              multiplier: parsedMultiplier!,
              // Same supply APY source as configure preview — see note above. (E4)
              collateralApy: market.economics.supplyApy,
              borrowApy: market.borrowAsset.borrowApy,
              maxLtv: market.risk.maxLtv,
            })
          : kind === "close"
            ? mapClosePreviewToActionUi(preview, {
                marketLabel,
                collateralSymbol: market.collateralAsset.symbol,
                liveCollateralValueUsd: position ? position.collateralAmount * collateralPriceUsd : undefined,
              })
            : mapDeleveragePreviewToActionUi(preview, {
                marketLabel,
                targetMultiplier: parsedMultiplier!,
                collateralSymbol: market.collateralAsset.symbol,
              })

      const simulated = session.readAdapter.mode === "sandbox"
      const result = await runActionSubmitFlow({
        simulated,
        needsAllowance: false,
        onStage: setStage,
        execute: async () => session.executeTransaction(preview.intent),
      })

      if (result.receipt.status !== "success") throw new Error(result.receipt.error ?? "Transaction failed")

      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: `${descriptor.primaryVerb} successful`,
          description:
            kind === "close"
              ? `${market.collateralAsset.symbol} position fully unwound and collateral withdrawn.`
              : `${parsedMultiplier!.toFixed(2)}x on ${market.collateralAsset.symbol} processed.`,
          receiptHash: result.receipt.hash ?? null,
          metrics: executionPreviewUi.metrics,
          href: dashboardHrefForProduct("multiply"),
          primaryCtaLabel: successDashboardCtaLabel("multiply"),
          preview: executionPreviewUi,
          verb: descriptor.primaryVerb,
        }),
      )
      setStage("success")
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Transaction was cancelled"
      // Raw backend codes stay in logs; users see plain-language copy (issue #143).
      if (process.env.NODE_ENV !== "production") console.error(rawMessage)
      setOutcome({
        tone: "error",
        title: "Something went wrong",
        message: actionErrorMessage(error, "Transaction was cancelled"),
      })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [
    amount,
    closeHref,
    collateralPriceUsd,
    collateralPriceStale,
    descriptor.primaryVerb,
    hasUserInput,
    isExitKind,
    isPending,
    kind,
    market,
    multiplier,
    previewUi,
    router,
    session,
    stage,
    successUi,
    walletId,
    position,
    walletPositions,
  ])

  const handleClose = useCallback(async () => {
    if (!market || isPending) return
    const closingPosition = walletPositions.find((entry) => entry.marketId === market.id)
    if (!closingPosition) return
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
      const action = {
        type: "close" as const,
        walletId,
        positionId: closingPosition.id,
        collateralPriceUsd,
      }
      const intent = session.createIntent(action)
      const preview = await session.previewTransaction(intent)
      if (!preview.allowed) throw new Error(preview.validationErrors[0] ?? "Action unavailable")

      const simulated = session.readAdapter.mode === "sandbox"
      const result = await runActionSubmitFlow({
        simulated,
        needsAllowance: false,
        onStage: setStage,
        execute: async () => session.executeTransaction(preview.intent),
      })

      if (result.receipt.status !== "success") throw new Error(result.receipt.error ?? "Transaction failed")

      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: t("Position closed"),
          description: t("Your {symbol} position was fully unwound and collateral withdrawn.").replace(
            "{symbol}",
            market.collateralAsset.symbol,
          ),
          receiptHash: result.receipt.hash ?? null,
          metrics: previewUi?.metrics ?? [],
          href: dashboardHrefForProduct("multiply"),
          primaryCtaLabel: successDashboardCtaLabel("multiply"),
          preview: previewUi ?? undefined,
          verb: "Close",
        }),
      )
      setStage("success")
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Transaction was cancelled"
      // Raw backend codes stay in logs; users see plain-language copy (issue #143).
      if (process.env.NODE_ENV !== "production") console.error(rawMessage)
      setOutcome({
        tone: "error",
        title: "Something went wrong",
        message: actionErrorMessage(error, "Transaction was cancelled"),
      })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [collateralPriceUsd, isPending, market, previewUi, session, walletId, walletPositions])

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

  // The catalog always has markets, so `market` is non-null in practice; this only
  // guards the impossible empty-catalog case (and never shows a dead-end card).
  if (!market) return null

  // Deleverage is the exit surface: whenever the wallet holds a position in this
  // market, offer a full Close/Withdraw so collateral can always be reclaimed —
  // including a fully-unwound 1.0x/$0 position that deleverage itself can no longer act on.
  const canClosePosition = kind === "deleverage" && position != null
  const deleverageCloseOnly = kind === "deleverage" && position != null && isDeleverageCloseOnly(position.multiplier)

  const hideTitle = embedded || stage === "success" || isSubmittingStage(stage) || stage === "review"
  const isHomeLayout = embedded && layout === "home"
  const shellDensity = sidebar ? "sidebar" : isHomeLayout ? "home" : "default"
  // Multiply slider is always the global 1–9.99 / 0.01 scale. Per-market publicMax remains an
  // engine hard-block (CTA disabled) when the user drags past it.
  const effectiveMultiplierMax = isExitKind
    ? getDeleverageMultiplierMax(position?.multiplier ?? Number.NaN, 0.1)
    : MULTIPLY_ACTION_SLIDER_MAX
  const multiplierStep = isExitKind ? 0.1 : MULTIPLY_ACTION_SLIDER_STEP
  const useWorkspaceFields = embedded && isHomeLayout && isConfigureVisibleStage(stage)
  // Surface the market-liquidity cap as the collateral input balance, with a Max button.
  const showCollateralBalance = kind === "multiply" && maxCollateralAmount != null && maxCollateralAmount > 0
  // Exit kinds show the position's collateral in the (read-only) Collateral field, so the user
  // can see what they are unwinding and which market it sits in.
  // Display-only, so format it: the raw float renders as "83364.92319002117" in the field.
  // This never feeds the action — close uses the positionId and deleverage the slider.
  const exitCollateralAmount =
    isExitKind && position
      ? position.collateralAmount >= 100
        ? position.collateralAmount.toFixed(2).replace(/\.?0+$/, "")
        : position.collateralAmount.toFixed(6).replace(/\.?0+$/, "")
      : ""
  const exitCollateralUsdLabel =
    isExitKind && position
      ? formatActionUsd(position.collateralAmount * collateralPriceUsd, { exact: true })
      : undefined
  // Multiply funds from its own "Available to loop" budget (the dashboard Multiply tab figure), not
  // the wallet balance, so name it the same way.
  const collateralBalanceLabel = showCollateralBalance
    ? "Available to loop"
    : isExitKind && position
      ? "Position"
      : undefined
  const collateralBalanceValue = showCollateralBalance
    ? formatActionAmount(maxCollateralAmount!, market.collateralAsset.symbol, 6)
    : isExitKind && position
      ? formatActionAmount(position.collateralAmount, market.collateralAsset.symbol, 6)
      : undefined
  const multiplierLabel = kind === "deleverage" ? "Target leverage" : "Multiplier"
  const stackedAmountField = useWorkspaceFields ? (
    <ActionConfigureAmountSection
      verb={descriptor.primaryVerb}
      inputLabel={kind === "multiply" ? "Collateral" : undefined}
      amount={amount}
      onAmountChange={(value) => {
        setHasUserInput(true)
        setAmount(value)
      }}
      preview={previewUi}
      assetSymbol={market.collateralAsset.symbol}
      assetLabel={market.collateralAsset.symbol}
      assetOptions={!validInitialMarketId ? marketOptions : undefined}
      selectedAssetId={market.id}
      onAssetSelect={(id) => {
        setHasUserInput(true)
        setSelectedMarketId(id)
        setAmount("")
      }}
      showBalance={showCollateralBalance}
      onMax={handleMaxCollateral}
      balanceLabel={collateralBalanceLabel}
      balanceValue={collateralBalanceValue}
      amountVariant="raised"
      amountFooter={
        <ActionLeverageRuler
          variant="embedded"
          value={displayMultiplier}
          onChange={(value) => {
            setHasUserInput(true)
            setMultiplier(value)
          }}
          min={multiplierMin}
          max={effectiveMultiplierMax}
          step={multiplierStep}
          label={multiplierLabel}
        />
      }
    />
  ) : null

  return (
    <ActionPageShell
      mode={embedded ? "embedded" : "page"}
      density={shellDensity}
      title={descriptor.title}
      subtitle={descriptor.subtitle}
      hideTitle={hideTitle}
      hideClose={embedded}
      closeHref={closeHref}
      flowHeaderStage={!embedded ? stage : undefined}
    >
      {useWorkspaceFields ? stackedAmountField : null}

      {isSubmittingStage(stage) ? (
        <ActionProcessingStage verb={descriptor.primaryVerb} preview={previewUi} closeHref={closeHref} stage={stage} />
      ) : null}

      {stage === "review" && previewUi ? (
        <ActionReviewStage
          title={reviewStageTitle(descriptor.primaryVerb)}
          subtitle="Confirm the details below before signing."
          hideHeader={embedded}
          preview={previewUi}
          primaryLabel={descriptor.primaryVerb}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          primaryPending={isPending}
          blockedReason={networkGuard.blockedReason}
        />
      ) : null}

      {stage === "success" && successUi ? <ActionSuccessStage success={successUi} closeHref={closeHref} /> : null}

      {isConfigureVisibleStage(stage) ? (
        <ActionConfigureStage
          stage={stage === "error" ? "configure" : stage}
          verb={descriptor.primaryVerb}
          inputLabel="Collateral"
          emptyReason={isExitKind && walletPositions.length === 0 ? "No open position" : undefined}
          amount={amount}
          // Read-only informational value; `amount` still drives validation, so showing the
          // position's collateral cannot make an unfilled form report as filled in.
          displayAmount={isExitKind ? exitCollateralAmount : undefined}
          // The exit field shows COLLATERAL, so its USD must be the collateral's value. The
          // preview's own amountUsd describes something else (the withdrawal for close, the
          // target leverage for deleverage), which rendered "$41,707" or "$0" beside it.
          amountUsdLabel={exitCollateralUsdLabel}
          onAmountChange={(value) => {
            setHasUserInput(true)
            setAmount(value)
          }}
          preview={previewUi}
          assetSymbol={market.collateralAsset.symbol}
          assetOptions={marketOptions}
          selectedAssetId={market.id}
          onAssetSelect={(id) => {
            setHasUserInput(true)
            setSelectedMarketId(id)
            setAmount("")
          }}
          multiplier={kind === "close" || deleverageCloseOnly ? undefined : displayMultiplier}
          onMultiplierChange={
            kind === "close" || deleverageCloseOnly
              ? undefined
              : (value) => {
                  setHasUserInput(true)
                  setMultiplier(value)
                }
          }
          multiplierMin={multiplierMin}
          multiplierMax={effectiveMultiplierMax}
          multiplierStep={multiplierStep}
          multiplierLabel={multiplierLabel}
          onPrimary={() => {
            if (deleverageCloseOnly) {
              void handleClose()
              return
            }
            void handlePrimary()
          }}
          onSecondary={handleBack}
          secondaryHref={closeHref}
          isPending={isPending}
          outcome={outcome}
          showBalance={showCollateralBalance || Boolean(isExitKind && position)}
          onMax={showCollateralBalance ? handleMaxCollateral : undefined}
          balanceLabel={collateralBalanceLabel}
          balanceValue={collateralBalanceValue}
          amountReadOnly={isExitKind}
          allowAssetSwitchWhenReadOnly={isExitKind}
          // Exit kinds keep the Collateral row visible: the amount is not user-editable (a
          // close is a full exit; a deleverage is driven by the slider) but the row carries
          // the position's collateral and the picker that selects WHICH position is being
          // exited. Hiding the whole row left Close/Deleverage with no collateral context at
          // all and no way off a market holding no position.
          hideAmountInput={useWorkspaceFields || (isExitKind && !position)}
          amountPlacement={useWorkspaceFields ? "stacked" : "inline"}
          homeLayout={isHomeLayout}
          singlePrimaryCta={sidebar || deleverageCloseOnly}
          // Exit kinds always keep the picker: choosing WHICH position to close is the
          // point, even in the home layout where opening is pinned to one market.
          hideAssetSelector={!isExitKind && isHomeLayout && Boolean(initialMarketId)}
        />
      ) : null}

      {canClosePosition && isConfigureVisibleStage(stage) ? (
        <button
          type="button"
          onClick={() => void handleClose()}
          disabled={isPending}
          className={
            deleverageCloseOnly
              ? "mt-3 w-full rounded-radius-lg bg-brand px-4 py-3 text-[15px] font-semibold text-brand-foreground transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"
              : "mt-3 w-full rounded-radius-lg border border-border/70 px-4 py-3 text-[15px] font-semibold text-muted-foreground transition-colors hover:text-foreground disabled:cursor-not-allowed disabled:opacity-60"
          }
          data-testid="multiply-close-position"
        >
          {t("Close position and withdraw collateral")}
        </button>
      ) : null}
    </ActionPageShell>
  )
}
