"use client"

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import {
  parseFixed,
  currentDebtValueUsd6,
  usd6ToNumber,
  wadToPercent,
} from "@/app/lib/borrow-system/model"
import {
  buildClaimBorrowAction,
  buildHomeClaimPreview,
  selectHomeBorrowTokensForMarket,
  selectHomeDebtMap,
  selectHomeRepayTokensForMarket,
} from "@/app/lib/borrow-system/action-preview-runtime"
import { buildRepayPreviewModel, buildWithdrawPreviewModel } from "@/app/lib/borrow-system/preview-builders"
import { filterPoolsForSpokeAsset } from "@/app/lib/borrow-detail/cross-market"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { useAvanaIdentity, useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import type { ActionKind, ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor, actionPagePath } from "@/app/lib/action-system/contracts"
import {
  mapBorrowSuccessToActionUi,
  mapBorrowRemovePreviewToActionUi,
  mapBorrowRepayPreviewToActionUi,
  mapBorrowSupplyPreviewToActionUi,
  mapBorrowTransactionPreviewToActionUi,
} from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { mapBorrowRewardsClaimPreviewToActionUi } from "@/app/lib/action-system/adapters/claim-fees-preview-mapper"
import { ActionBorrowContextBar } from "@/app/components/action-page/action-borrow-context-bar"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage, ActionConfigureAmountSection } from "@/app/components/action-page/action-configure-stage"
import { ActionLeverageRuler } from "@/app/components/action-page/action-leverage-ruler"
import { ActionSelectStage } from "@/app/components/action-page/action-select-stage"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"
import { formatActionAmount, formatActionUsd } from "@/app/lib/action-system/formatters"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { actionErrorMessage, humanizeBlockedReason } from "@/app/lib/action-system/blocked-reason"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { formatBorrowLpSymbolLabel, formatBorrowMarketLabel } from "@/app/lib/borrow-system/market-labels"
import {
  borrowSelectItemsForMarket,
  claimSelectItemsForWallet,
  repaySelectItemsForWallet,
  removeSelectItemsForWallet,
  resolveBorrowAssetId,
  resolveBorrowMarketForAsset,
  resolveBorrowTokenSelection,
  resolveClaimMarketId,
  supplySelectItemsForWallet,
} from "@/app/lib/action-system/resolve-borrow-context"
import {
  isConfigureVisibleStage,
  isProcessingStage,
  isSubmittingStage,
  reviewStageTitle,
} from "@/app/lib/action-system/stage-machine"
import { parseActionPercentBps, parsePositiveActionAmount } from "@/app/lib/action-system/amount-input"
import { repayUsdForTokenAmount, resolveClaimPositions, selectionsFromPositions } from "./borrow-action-selection"

export function BorrowActionPageClient({
  kind,
  closeHref = "/borrow",
  embedded = false,
  sidebar = false,
  layout = "default",
  initialAssetId,
  initialMarketId,
  initialAmount = "",
  initialPositionId,
  initialDebtId,
}: {
  kind: Extract<ActionKind, "borrow" | "repay" | "supply" | "remove" | "claim">
  closeHref?: string
  embedded?: boolean
  sidebar?: boolean
  layout?: "default" | "home"
  initialAssetId?: string
  initialMarketId?: string
  initialAmount?: string
  initialPositionId?: string
  initialDebtId?: string
}) {
  const descriptor = getActionDescriptor("borrow", kind)
  const router = useRouter()
  const { walletId } = useAvanaIdentity()
  const session = useBorrowSessionContext()
  // Home Express starts every action from an unselected ("0") state so the user
  // picks the collateral/position first, rather than auto-picking the first pool.
  const isHomeZeroState =
    embedded && layout === "home" && !initialMarketId && !initialAssetId && !initialDebtId && !initialPositionId
  const isHomeBorrowZeroState = isHomeZeroState && kind === "borrow"
  // Borrow and supply can target ANY market in the catalog — you pledge collateral
  // as part of the flow — so their pool picker is the full available list (not just
  // the markets already pledged). Repay/remove/claim act on existing positions, so
  // they keep the pledged-pool list.
  const usesAllMarketPools = kind === "borrow" || kind === "supply"
  // The home express borrow should surface the wallet's already-pledged pools (with
  // real collateral values) when it has them, so a user can borrow against existing
  // collateral — the same source the dashboard/Repay tab use — instead of a list of
  // $0 unpledged catalog markets that dead-ends at "Available $0.00". A fresh wallet
  // with no positions still falls back to the full catalog so it can pledge.
  const preferPledgedPools = isHomeBorrowZeroState && session.collateralPools.length > 0
  const unscopedCollateralPoolOptions =
    usesAllMarketPools && !preferPledgedPools ? session.availableCollateralPools : session.collateralPools
  // Asset detail sidebar: only show collateral pools that unlock THIS borrowable
  // (same spoke / marketIds). Home Express keeps the full catalog for discovery.
  const scopeCollateralToAsset = Boolean(sidebar && initialAssetId && (kind === "borrow" || kind === "repay"))
  const collateralPoolOptions = useMemo(() => {
    if (!scopeCollateralToAsset || !initialAssetId) return unscopedCollateralPoolOptions
    return filterPoolsForSpokeAsset(session.state.assets[initialAssetId]?.marketIds, unscopedCollateralPoolOptions)
  }, [initialAssetId, scopeCollateralToAsset, unscopedCollateralPoolOptions])
  const hasInvalidInitialMarket = Boolean(
    initialMarketId &&
    !initialAssetId &&
    // A market is "available" whenever it exists in the catalog — the wallet may
    // simply not hold a position in it yet (never a dead-end). Borrow/supply
    // validate against the full catalog; repay/remove/claim need a pledged position.
    (usesAllMarketPools
      ? !session.state.markets[initialMarketId]
      : !session.collateralPools.some((pool) => pool.id === initialMarketId)),
  )
  const resolvedInitialMarket = useMemo(() => {
    if (initialAssetId) {
      return resolveBorrowMarketForAsset(session, initialAssetId, hasInvalidInitialMarket ? undefined : initialMarketId)
    }
    if (initialMarketId && !hasInvalidInitialMarket) return initialMarketId
    return undefined
  }, [hasInvalidInitialMarket, initialAssetId, initialMarketId, session])
  const resolvedInitialAsset = useMemo(
    () => (initialAssetId ? resolveBorrowAssetId(session.state, initialAssetId, resolvedInitialMarket) : ""),
    [initialAssetId, resolvedInitialMarket, session.state],
  )
  const [stage, setStage] = useState<ActionStage>(() => {
    if (embedded) return "configure"
    // A bad/unknown market id lands on the picker (pick a market) rather than a
    // "Market unavailable" dead-end.
    if (hasInvalidInitialMarket) return "select"
    if (kind === "borrow" && !resolvedInitialAsset) return "select"
    if (kind === "supply" && !initialMarketId) return "select"
    if (kind === "claim" && !initialMarketId && !initialPositionId) return "select"
    if (kind === "repay" && !initialDebtId && !resolvedInitialAsset) return "select"
    if (kind === "remove" && !initialMarketId && !initialPositionId) return "select"
    return "configure"
  })
  const [assetId, setAssetId] = useState(resolvedInitialAsset)
  const [marketId, setMarketId] = useState(
    isHomeZeroState
      ? ""
      : (resolvedInitialMarket ?? (hasInvalidInitialMarket ? "" : (session.collateralPools[0]?.id ?? ""))),
  )
  const [amount, setAmount] = useState(initialAmount)
  // The input stays bound to `amount` for instant typing feedback, but the expensive
  // engine preview (previewTransaction) below keys off this deferred value so it runs
  // on the settled value instead of once per keystroke — the main INP lever here.
  const deferredAmount = useDeferredValue(amount)
  const [percent, setPercent] = useState(() => (kind === "remove" ? initialAmount : "25"))
  // Same rationale as deferredAmount: the remove-collateral slider feeds the engine
  // preview, so defer it too and drag stays smooth without an engine call per pointer move.
  const deferredPercent = useDeferredValue(percent)
  const [previewUi, setPreviewUi] = useState<ActionPreviewUi | null>(null)
  const [reviewPreviewUi, setReviewPreviewUi] = useState<ActionPreviewUi | null>(null)
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [claimPositionId, setClaimPositionId] = useState(initialPositionId ?? "")
  const [outcome, setOutcome] = useState<{ tone: "error" | "success"; title: string; message: string } | null>(null)
  // Wrong-network submit gate. Read through a ref inside handlePrimary so the (heavily-memoised)
  // callback always sees the current chain without being rebuilt on every network change.
  const networkGuard = useActionNetworkGuard()
  const networkGuardRef = useRef(networkGuard)
  networkGuardRef.current = networkGuard
  const [isPending, setIsPending] = useState(false)
  const lastInitialAssetIdRef = useRef(initialAssetId)
  const lastInitialMarketIdRef = useRef(initialMarketId)

  // Accrued to now so Outstanding debt and Max include the interest since the last write (the
  // dashboard figure); the stored index made a "full" repay leave that interest behind.
  const debtPositions = useMemo(
    () => session.state.accounts[walletId]?.debtPositions ?? [],
    [session.state, walletId],
  )
  const [debtPositionId, setDebtPositionId] = useState(initialDebtId ?? "")

  const debtPosition = useMemo(() => {
    if (debtPositionId) {
      return debtPositions.find((position) => position.id === debtPositionId) ?? null
    }
    if (kind !== "repay") return null
    if (initialMarketId) {
      return (
        debtPositions.find((position) => position.marketId === initialMarketId) ??
        debtPositions.find((position) => {
          const spokeId = session.state.markets[initialMarketId]?.spokeId
          if (!spokeId || !position.marketId) return false
          return session.state.markets[position.marketId]?.spokeId === spokeId
        }) ??
        null
      )
    }
    // Home zero-state: don't auto-pick a debt until the user selects a collateral,
    // so the field starts at "0" instead of jumping to the first position's market.
    if (isHomeZeroState && !marketId) return null
    // Otherwise resolve to a real debt — the one in the currently selected market,
    // else the sole/first debt. Never leave it null off the zero-state, which
    // defaulted the repay asset to the market's first collateral token (e.g. WETH)
    // instead of the asset actually owed (e.g. USDC).
    return debtPositions.find((position) => position.marketId === marketId) ?? debtPositions[0] ?? null
  }, [debtPositionId, debtPositions, initialMarketId, isHomeZeroState, kind, marketId, session.state.markets])

  const activeMarketId = hasInvalidInitialMarket
    ? ""
    : marketId || (isHomeZeroState ? "" : session.collateralPools[0]?.id || "")
  const selectMarketId = activeMarketId
  const resolvedBorrowAssetId = useMemo(
    () => (kind === "borrow" && assetId ? resolveBorrowAssetId(session.state, assetId, activeMarketId) : ""),
    [activeMarketId, assetId, kind, session.state],
  )
  const debts = useMemo(() => selectHomeDebtMap(session.state, walletId), [session.state, walletId])
  const activePool = useMemo(() => {
    const matched = collateralPoolOptions.find((pool) => pool.id === activeMarketId)
    if (matched) return matched
    // In the home zero-state we intentionally render no pre-selected pool (no
    // collateral value, no health factor) until the user picks one — so don't
    // fall back to the first pledged pool here.
    if (isHomeZeroState) return null
    return collateralPoolOptions[0] ?? null
  }, [activeMarketId, collateralPoolOptions, isHomeZeroState])
  const borrowTokens = useMemo(
    () =>
      activeMarketId
        ? selectHomeBorrowTokensForMarket(session.state, walletId, activeMarketId)
        : isHomeBorrowZeroState
          ? // Zero-state (no collateral picked yet): expose the full borrowable set so the
            // asset picker opens the SAME dialog as when collateral is selected, rather
            // than degrading to a plain dropdown (empty market => all borrowable assets).
            selectHomeBorrowTokensForMarket(session.state, walletId, "")
          : [],
    [activeMarketId, isHomeBorrowZeroState, session.state, walletId],
  )
  const repayTokens = useMemo(
    () => (activeMarketId ? selectHomeRepayTokensForMarket(session.state, walletId, activeMarketId) : []),
    [activeMarketId, session.state, walletId],
  )
  const usesCollateralContext = kind === "borrow" || kind === "repay" || kind === "remove" || kind === "claim"
  const showCollateralContextBar =
    usesCollateralContext &&
    (isConfigureVisibleStage(stage) || stage === "review") &&
    (activePool != null || isHomeZeroState)

  const handlePoolChange = useCallback(
    (poolId: string) => {
      // Asset detail: switching collateral navigates to that pool's market page so
      // the whole details surface (hero, about, stats) matches the selected collateral.
      if (scopeCollateralToAsset && poolId && poolId !== activeMarketId) {
        router.push(borrowMarketDetailPath(poolId))
        return
      }

      setMarketId(poolId)
      setAmount("")
      setPercent(kind === "remove" ? initialAmount : "25")
      if (kind === "borrow") {
        // Prefer keeping the same base asset on the new pool's spoke (GHO stays GHO)
        // instead of blindly taking the market's first borrowable token.
        const preferred = assetId.trim().length > 0 ? resolveBorrowAssetId(session.state, assetId, poolId) : ""
        if (preferred) {
          setAssetId(preferred)
          return
        }
        const tokens = selectHomeBorrowTokensForMarket(session.state, walletId, poolId)
        const nextAssetId = tokens[0]?.id ?? ""
        setAssetId(nextAssetId ? resolveBorrowAssetId(session.state, nextAssetId, poolId) : "")
        return
      }
      if (kind === "repay") {
        const position =
          debtPositions.find((entry) => entry.marketId === poolId) ??
          debtPositions.find((entry) => {
            const spokeId = session.state.markets[poolId]?.spokeId
            return spokeId ? entry.spokeId === spokeId : false
          }) ??
          null
        if (position) setDebtPositionId(position.id)
        return
      }
      if (kind === "claim") {
        setClaimPositionId("")
      }
    },
    [
      activeMarketId,
      assetId,
      debtPositions,
      initialAmount,
      kind,
      router,
      scopeCollateralToAsset,
      session.state,
      walletId,
    ],
  )

  const selectItems = useMemo(() => {
    if (kind === "repay") return repaySelectItemsForWallet(session, walletId)
    if (kind === "claim") return claimSelectItemsForWallet(session, walletId)
    if (kind === "supply") return supplySelectItemsForWallet(session, walletId)
    if (kind === "remove") return removeSelectItemsForWallet(session, walletId)
    return borrowSelectItemsForMarket(session, selectMarketId || undefined, walletId)
  }, [kind, selectMarketId, session, walletId])

  const borrowAssetOptions = useMemo(() => {
    if (kind !== "borrow") return undefined
    const options = session.getBorrowableAssetsForMarket(activeMarketId).map((asset) => ({
      id: asset.id,
      label: asset.symbol,
      symbol: asset.symbol,
    }))
    return options.length > 1 ? options : undefined
  }, [activeMarketId, kind, session])

  const marketLabel = useMemo(() => {
    const market = session.marketSummaries.find((entry) => entry.id === marketId)
    return market ? formatBorrowMarketLabel(market) : "Collateral pool"
  }, [marketId, session.marketSummaries])

  const creditScopeLabel = useMemo(() => {
    const scopedMarketId = kind === "borrow" ? activeMarketId : (debtPosition?.marketId ?? marketId ?? activeMarketId)
    const market = scopedMarketId ? session.state.markets[scopedMarketId] : null
    if (!market) return null
    return market.display.venue || market.spokeId
  }, [activeMarketId, debtPosition?.marketId, kind, marketId, session.state.markets])

  const repayAssetOptions = useMemo(() => {
    if (kind !== "repay" || !debtPosition) return undefined
    const options = debtPositions
      .filter((position) => position.marketId === debtPosition.marketId)
      .map((position) => {
        const asset = session.state.assets[position.assetId]
        const debtUsd = usd6ToNumber(currentDebtValueUsd6(position))
        return {
          id: position.id,
          label: asset?.symbol ?? "Asset",
          symbol: asset?.symbol ?? "Asset",
          sublabel: formatActionUsd(debtUsd),
        }
      })
    return options.length > 1 ? options : undefined
  }, [debtPosition, debtPositions, kind, session.state.assets])

  // Outstanding debt for the selected repay position, resolved off the state (not the
  // async preview) so the "Outstanding debt" hint and Max show on the empty step too.
  const repayDebtHint = useMemo(() => {
    if (kind !== "repay" || !debtPosition) return null
    const priceUsd = usd6ToNumber(session.state.assets[debtPosition.assetId]?.snapshot.priceUsd6 ?? 0n)
    const debtUsd = usd6ToNumber(currentDebtValueUsd6(debtPosition))
    const maxTokens = priceUsd > 0 ? debtUsd / priceUsd : debtUsd
    const symbol = session.state.assets[debtPosition.assetId]?.symbol
    return {
      debtUsd,
      // In the debt token, the unit typed into the field ("944.83 USDC", not "$944.70").
      valueLabel:
        priceUsd > 0 && symbol ? formatActionAmount(maxTokens, symbol, 4) : formatActionUsd(debtUsd, { exact: true }),
      maxTokens,
    }
  }, [kind, debtPosition, session.state.assets])

  const claimAssetOptions = useMemo(() => {
    if (kind !== "claim") return undefined
    const options = claimSelectItemsForWallet(session, walletId).map((item) => ({
      id: item.id,
      label: item.name,
      symbol: item.symbol,
      sublabel: item.trailingLabel,
    }))
    return options.length > 1 ? options : undefined
  }, [kind, session, walletId])

  const supplyPairSymbols = useMemo(() => {
    if (kind !== "supply" && kind !== "remove") return null
    const market = session.state.markets[marketId]
    const visuals = market?.display.visuals
    if (!visuals || visuals.length < 2) return null
    return [visuals[0]!.symbol, visuals[1]!.symbol] as const
  }, [kind, marketId, session.state.markets])

  const supplyAssetOptions = useMemo(() => {
    if (kind !== "supply") return undefined
    const options = supplySelectItemsForWallet(session, walletId).map((item) => {
      const market = session.state.markets[item.id]
      const visuals = market?.display.visuals ?? []
      return {
        id: item.id,
        label: item.name,
        symbol: visuals[0]?.symbol ?? item.symbol,
        borrowSymbol: visuals[1]?.symbol,
        sublabel: item.sublabel,
      }
    })
    return options.length > 1 ? options : undefined
  }, [kind, session, walletId])

  const assetSymbol = useMemo(() => {
    if (kind === "remove" || kind === "supply") {
      return formatBorrowLpSymbolLabel(session.state.markets[marketId])
    }
    const resolvedAssetId =
      resolvedBorrowAssetId || (assetId ? resolveBorrowAssetId(session.state, assetId, activeMarketId) : "")
    if (resolvedAssetId) {
      return session.state.assets[resolvedAssetId]?.symbol ?? previewUi?.amountLabel.split(" ").slice(-1)[0]
    }
    if (debtPosition) return session.state.assets[debtPosition.assetId]?.symbol
    const market = session.state.markets[marketId]
    return market?.display.visuals[0]?.symbol ?? "Asset"
  }, [
    activeMarketId,
    assetId,
    debtPosition,
    kind,
    previewUi?.amountLabel,
    resolvedBorrowAssetId,
    session.state.assets,
    session.state.markets,
  ])

  useEffect(() => {
    if (initialPositionId) setClaimPositionId(initialPositionId)
  }, [initialPositionId])

  useEffect(() => {
    if (initialDebtId) setDebtPositionId(initialDebtId)
  }, [initialDebtId])

  useEffect(() => {
    if (kind !== "repay" || !initialMarketId || !resolvedInitialAsset || debtPositionId) return
    const position = debtPositions.find(
      (entry) => entry.marketId === initialMarketId && entry.assetId === resolvedInitialAsset,
    )
    if (position) setDebtPositionId(position.id)
  }, [debtPositionId, debtPositions, initialMarketId, kind, resolvedInitialAsset])

  useEffect(() => {
    if (embedded || kind !== "repay" || initialMarketId || initialDebtId || debtPositionId) return
    if (debtPositions.length === 1) {
      setDebtPositionId(debtPositions[0]!.id)
      if (debtPositions[0]!.marketId) setMarketId(debtPositions[0]!.marketId)
      return
    }
    if (debtPositions.length > 1) setStage("select")
  }, [debtPositionId, debtPositions, embedded, initialDebtId, initialMarketId, kind])

  useEffect(() => {
    if (embedded || kind !== "borrow" || !assetId) return
    const resolvedMarket = resolveBorrowMarketForAsset(session, assetId, marketId)
    if (resolvedMarket && resolvedMarket !== marketId) {
      setMarketId(resolvedMarket)
    }
  }, [assetId, embedded, kind, marketId, session])

  useEffect(() => {
    if (embedded || !initialAssetId) return
    if (lastInitialAssetIdRef.current === initialAssetId) return
    lastInitialAssetIdRef.current = initialAssetId
    const resolved = resolveBorrowAssetId(session.state, initialAssetId, resolvedInitialMarket)
    if (resolved && resolved !== assetId) {
      setAssetId(resolved)
    }
    if (stage === "select") {
      setStage("configure")
    }
  }, [assetId, embedded, initialAssetId, resolvedInitialMarket, session.state, stage])

  useEffect(() => {
    if (kind !== "borrow" || !activeMarketId || borrowTokens.length === 0) return

    // Keep a user/route selection that is valid on the active market.
    const currentResolved = assetId ? resolveBorrowAssetId(session.state, assetId, activeMarketId) : ""
    if (currentResolved && borrowTokens.some((token) => token.id === currentResolved)) {
      if (assetId !== currentResolved) setAssetId(currentResolved)
      return
    }

    // Selection missing or off-market (e.g. snapped to another spoke): prefer the
    // deep-linked asset (bal-stable:gho) before the market's first borrowable.
    const routeAssetId = initialAssetId ? resolveBorrowAssetId(session.state, initialAssetId, activeMarketId) : ""
    if (routeAssetId && borrowTokens.some((token) => token.id === routeAssetId)) {
      if (assetId !== routeAssetId) setAssetId(routeAssetId)
      return
    }

    setAssetId(borrowTokens[0]!.id)
  }, [activeMarketId, assetId, borrowTokens, initialAssetId, kind, session.state])

  useEffect(() => {
    if (embedded || !initialMarketId) return
    if (lastInitialMarketIdRef.current === initialMarketId) return
    lastInitialMarketIdRef.current = initialMarketId
    if (marketId !== initialMarketId) {
      setMarketId(initialMarketId)
    }
    if ((kind === "supply" || kind === "remove" || kind === "repay" || resolvedInitialAsset) && stage === "select") {
      setStage("configure")
    }
  }, [embedded, initialMarketId, kind, marketId, resolvedInitialAsset, stage])

  useEffect(() => {
    if (initialAssetId && resolvedInitialMarket) {
      setMarketId(resolvedInitialMarket)
    }
  }, [initialAssetId, resolvedInitialMarket])

  useEffect(() => {
    if (debtPosition?.marketId) setMarketId(debtPosition.marketId)
  }, [debtPosition?.marketId])

  useEffect(() => {
    if (embedded || kind !== "supply" || initialMarketId || marketId) return
    const items = supplySelectItemsForWallet(session, walletId)
    if (items.length === 1) {
      setMarketId(items[0]!.id)
    }
  }, [embedded, initialMarketId, kind, marketId, session, walletId])

  useEffect(() => {
    if (!embedded || usesCollateralContext === false || session.collateralPools.length === 0 || isHomeZeroState) return
    // Asset-detail sidebar scopes collateral to the borrowable's spoke catalog, which
    // includes unpledged markets. Do not snap back to the wallet's first pledged pool
    // (that was replacing Balancer GHO with an unrelated Aerodrome market).
    if (scopeCollateralToAsset) return
    if (marketId && session.collateralPools.some((pool) => pool.id === marketId)) return
    setMarketId(session.collateralPools[0]!.id)
  }, [embedded, isHomeZeroState, marketId, scopeCollateralToAsset, session.collateralPools, usesCollateralContext])

  useEffect(() => {
    // executeTransaction updates the shared session during reconciliation. Keep the reviewed
    // preview stable across the submit lifecycle; rerunning here clears it and makes the
    // health-factor bar visibly jump.
    if (stage !== "configure" && stage !== "review" && stage !== "error") return undefined
    let cancelled = false
    const safeAmount = parsePositiveActionAmount(deferredAmount) ?? 0

    if (kind === "borrow") {
      const resolvedAssetId = resolvedBorrowAssetId
      const borrowAsset = resolvedAssetId ? session.state.assets[resolvedAssetId] : undefined
      const priceUsd = borrowAsset ? usd6ToNumber(borrowAsset.snapshot.priceUsd6) : 0
      if (!resolvedAssetId || !borrowAsset || priceUsd <= 0 || safeAmount <= 0) {
        setPreviewUi(null)
        return undefined
      }
      // The typed amount is a TOKEN quantity; the credit engine denominates debt in
      // USD, so price it with the live oracle before previewing/executing.
      const usdValue = safeAmount * priceUsd
      void session
        .previewTransaction(
          session.createIntent({
            type: "borrow",
            walletId,
            marketId: activeMarketId,
            assetId: resolvedAssetId,
            amountUsd6: parseFixed(usdValue.toFixed(6), 6),
          }),
        )
        .then((preview) => {
          if (cancelled) return
          const token = session
            .getBorrowableAssetsForMarket(activeMarketId)
            .find((entry) => entry.id === resolvedAssetId)
          const borrowMarket = session.state.markets[activeMarketId]
          const liquidationThresholdPct = borrowMarket
            ? wadToPercent(borrowMarket.riskConfig.liquidationThresholdWad)
            : undefined
          // Max borrow respects the collateral factor: pre-borrow available credit
          // is the safe cap the credit engine will allow.
          const maxBorrowUsd = usd6ToNumber(preview.before.availableBorrowCapacityUsd6)
          setPreviewUi(
            mapBorrowTransactionPreviewToActionUi(preview, {
              symbol: token?.symbol ?? "Asset",
              amountUsd: usdValue,
              priceUsd,
              marketLabel,
              ratePct: token?.borrowApr ?? 0,
              balanceLabel: "Available to borrow",
              balanceUsd: maxBorrowUsd,
              liquidationThresholdPct,
              maxBorrowUsd,
              creditScopeLabel: creditScopeLabel ?? undefined,
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

    if (kind === "supply") {
      if (safeAmount <= 0) {
        setPreviewUi(null)
        return undefined
      }
      const market = session.state.markets[marketId]
      const collateralFactorPct = market ? wadToPercent(market.riskConfig.collateralFactorWad) : 0
      const liquidationPct = market ? wadToPercent(market.riskConfig.liquidationThresholdWad) : 0
      const borrowableAssets = session.getBorrowableAssetsForMarket(marketId)
      const walletBalanceUsd = usd6ToNumber(session.state.accounts[walletId]?.walletLpBalancesUsd6[marketId] ?? 0n)
      void session
        .previewTransaction(
          session.createIntent({
            type: "supplyCollateral",
            walletId,
            marketId,
            amountUsd6: parseFixed(safeAmount.toFixed(6), 6),
          }),
        )
        .then((preview) => {
          if (cancelled) return
          setPreviewUi(
            mapBorrowSupplyPreviewToActionUi(preview, {
              symbol: formatBorrowLpSymbolLabel(market),
              amountUsd: safeAmount,
              marketLabel,
              poolLabel: market?.display.name ?? marketLabel,
              collateralSymbol: market?.display.visuals[0]?.symbol ?? "LP",
              borrowSymbol: market?.display.visuals[1]?.symbol ?? "",
              collateralFactorPct,
              collateralRiskPct: Math.max(0, liquidationPct - collateralFactorPct),
              borrowableAssetsLabel: borrowableAssets.map((asset) => asset.symbol).join(", ") || "—",
              borrowableAssetSymbols: borrowableAssets.map((asset) => asset.symbol),
              creditScopeLabel: creditScopeLabel ?? undefined,
              walletBalanceUsd,
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

    if (kind === "repay") {
      const repay = debtPosition ? repayUsdForTokenAmount(session.state, debtPosition.assetId, safeAmount) : null
      if (safeAmount <= 0 || !debtPosition || !repay) {
        setPreviewUi(null)
        return undefined
      }
      const { priceUsd: repayPriceUsd, amountUsd: repayAmountUsd } = repay
      const repayPreview = buildRepayPreviewModel(session.state, walletId, debtPosition.id, repayAmountUsd)
      void session
        .previewTransaction(
          session.createIntent({
            type: "repay",
            walletId,
            debtPositionId: debtPosition.id,
            assetId: debtPosition.assetId,
            amountUsd6: parseFixed(repayAmountUsd.toFixed(6), 6),
            at: Date.now(),
          }),
        )
        .then((preview) => {
          if (cancelled) return
          const token = session.state.assets[debtPosition.assetId]
          setPreviewUi(
            mapBorrowRepayPreviewToActionUi(preview, {
              symbol: token?.symbol ?? "Asset",
              amountUsd: repayAmountUsd,
              priceUsd: repayPriceUsd,
              marketLabel,
              remainingDebtUsd: repayPreview.remainingDebtUsd,
              yearlyInterestSavedUsd: repayPreview.yearlyInterestSavedUsd,
              creditScopeLabel: creditScopeLabel ?? undefined,
              exceedsDebt: repayPreview.exceedsDebt,
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

    if (kind === "remove") {
      const percentBps = parseActionPercentBps(deferredPercent)
      const position = session.state.accounts[walletId]?.collateralPositions.find(
        (entry) => entry.marketId === marketId,
      )
      if (percentBps == null || !position) {
        setPreviewUi(null)
        return undefined
      }
      const pct = percentBps / 100
      const removePreview = buildWithdrawPreviewModel(session.state, walletId, marketId, pct)
      const pool = session.collateralPools.find((entry) => entry.id === marketId)
      void session
        .previewTransaction(
          session.createIntent({
            type: "removeCollateral",
            walletId,
            positionId: position.id,
            percentBps,
          }),
        )
        .then((preview) => {
          if (cancelled) return
          setPreviewUi(
            mapBorrowRemovePreviewToActionUi(preview, {
              percent: pct,
              safePercent: removePreview.safePercent,
              removeUsd: removePreview.removeUsd,
              marketLabel,
              positionApyPct: pool?.pairApr ?? 0,
              creditScopeLabel: creditScopeLabel ?? undefined,
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

    if (kind === "claim") {
      // Home zero-state: nothing selected yet, so show no claim summary until the
      // user picks a collateral pool.
      if (isHomeZeroState && !marketId) {
        setPreviewUi(null)
        return undefined
      }
      const positions = resolveClaimPositions(session, walletId, marketId, claimPositionId)
      const selections = selectionsFromPositions(positions)
      const claimPreview = buildHomeClaimPreview(session.state, walletId, positions, selections, safeAmount || null)
      setPreviewUi(
        mapBorrowRewardsClaimPreviewToActionUi({
          allowed: claimPreview.hasSelection && claimPreview.effectiveClaimUsd > 0,
          claimUsd: claimPreview.effectiveClaimUsd,
          marketLabel,
          tokenTotals: claimPreview.tokenTotals,
          blockedReason: claimPreview.hasSelection ? null : "Select rewards to claim",
        }),
      )
    }
    return undefined
  }, [
    activeMarketId,
    deferredAmount,
    assetId,
    claimPositionId,
    creditScopeLabel,
    debtPosition,
    isHomeZeroState,
    kind,
    marketId,
    marketLabel,
    deferredPercent,
    resolvedBorrowAssetId,
    session,
    stage,
    walletId,
  ])

  useEffect(() => {
    // Editing inputs after a failed submit clears the stale error banner and drops back to
    // configure, so the CTA is actionable again instead of stuck showing the old error.
    setOutcome(null)
    setStage((prev) => (prev === "error" ? "configure" : prev))
  }, [amount, assetId, claimPositionId, debtPositionId, marketId, percent])

  const canGoBackToSelect = useMemo(() => {
    if (embedded) return false
    if (kind === "borrow" && !resolvedInitialAsset) return true
    if (kind === "supply" && !initialMarketId && supplySelectItemsForWallet(session, walletId).length > 1) return true
    if (kind === "repay" && debtPositions.length > 1 && !initialMarketId && !initialDebtId) return true
    if (kind === "remove" && !initialMarketId && !initialPositionId && selectItems.length > 1) return true
    if (
      kind === "claim" &&
      claimSelectItemsForWallet(session, walletId).length > 1 &&
      !initialMarketId &&
      !initialPositionId
    )
      return true
    return false
  }, [
    debtPositions.length,
    embedded,
    initialMarketId,
    initialPositionId,
    initialDebtId,
    kind,
    resolvedInitialAsset,
    selectItems.length,
    session,
    walletId,
  ])

  useEffect(() => {
    if (previewUi == null || successUi != null) return
    // Only recover the success screen while a submit is in flight. Matching on the
    // "configure" stage too let a revisit within 15s of any same-market success
    // auto-jump to a phantom "successful" screen without the user submitting.
    if (!isProcessingStage(stage)) return

    const minTimestamp = Date.now() - 15_000

    const matchingHistory = session.transactionHistory.find((item) => {
      if (item.status !== "success" || item.timestamp < minTimestamp) return false
      switch (kind) {
        case "borrow":
          if (item.kind !== "borrow") return false
          return item.marketId === activeMarketId && item.assetId === resolvedBorrowAssetId
        case "repay":
          if (item.kind !== "repay") return false
          return debtPosition ? item.assetId === debtPosition.assetId : true
        case "supply":
          if (item.kind !== "deposit") return false
          return item.marketId === marketId
        case "remove":
          if (item.kind !== "withdraw") return false
          return item.marketId === marketId
        case "claim":
          if (item.kind !== "claim") return false
          return item.marketId === marketId
        default:
          return false
      }
    })

    if (!matchingHistory) return

    const executedAmount = usd6ToNumber(matchingHistory.executedAmountUsd6)
    setSuccessUi(
      mapBorrowSuccessToActionUi({
        title: `${descriptor.primaryVerb} successful`,
        // Always exact so tiny pledge amounts never render as a truncated "$0." fragment.
        description: `${formatActionUsd(executedAmount, { exact: true })} processed.`,
        receiptHash: matchingHistory.hash ?? null,
        metrics: previewUi.metrics,
        href: dashboardHrefForProduct("borrow"),
        primaryCtaLabel: successDashboardCtaLabel("borrow"),
        preview: previewUi,
        verb: descriptor.primaryVerb,
      }),
    )
    setStage("success")
  }, [
    activeMarketId,
    debtPosition,
    descriptor.primaryVerb,
    kind,
    marketId,
    previewUi,
    resolvedBorrowAssetId,
    session.transactionHistory,
    stage,
    successUi,
  ])

  const handleBack = useCallback(() => {
    if (stage === "review") {
      setReviewPreviewUi(null)
      setStage("configure")
      setOutcome(null)
      return
    }
    if (stage === "configure" && canGoBackToSelect) {
      router.replace(actionPagePath("borrow", kind))
      return
    }
    router.push(closeHref)
  }, [canGoBackToSelect, closeHref, kind, router, stage])

  const handlePrimary = useCallback(async () => {
    const submittedPreviewUi = reviewPreviewUi ?? previewUi
    if (stage === "success") {
      router.push(successUi?.primaryCtaHref ?? dashboardHrefForProduct("borrow"))
      return
    }
    if (stage === "configure") {
      if (!previewUi?.allowed) return
      setReviewPreviewUi(previewUi)
      setStage("review")
      return
    }
    if (stage !== "review" && stage !== "error") return // allow in-place retry from error
    if (!submittedPreviewUi?.allowed) return
    if (isPending) return // guard against double-submit (rapid double-click)
    if (networkGuardRef.current.isWrongNetwork) {
      // Hard gate: never submit against a chain the app doesn't support (the banner alone
      // did not stop this). The confirm CTA is also disabled via ActionReviewStage.
      setOutcome({
        tone: "error",
        title: "Wrong network",
        message: networkGuardRef.current.blockedReason ?? "Switch networks to continue.",
      })
      return
    }

    setOutcome(null)
    setIsPending(true)

    try {
      const safeAmount = parsePositiveActionAmount(amount) ?? 0
      let intent

      if (kind === "borrow") {
        if (!resolvedBorrowAssetId) throw new Error("Select a borrow asset")
        const borrowPriceUsd = usd6ToNumber(session.state.assets[resolvedBorrowAssetId]?.snapshot.priceUsd6 ?? 0n)
        if (borrowPriceUsd <= 0) throw new Error("Missing borrow-asset price")
        // Typed amount is a token quantity; the engine borrows a USD value.
        intent = session.createIntent({
          type: "borrow",
          walletId,
          marketId: activeMarketId,
          assetId: resolvedBorrowAssetId,
          amountUsd6: parseFixed((safeAmount * borrowPriceUsd).toFixed(6), 6),
        })
      } else if (kind === "supply") {
        intent = session.createIntent({
          type: "supplyCollateral",
          walletId,
          marketId,
          amountUsd6: parseFixed(safeAmount.toFixed(6), 6),
        })
      } else if (kind === "repay") {
        if (!debtPosition) throw new Error("No debt selected")
        // Typed amount is a debt-token quantity; the engine repays a USD value.
        const repay = repayUsdForTokenAmount(session.state, debtPosition.assetId, safeAmount)
        if (!repay) throw new Error("Missing repay-asset price")
        intent = session.createIntent({
          type: "repay",
          walletId,
          debtPositionId: debtPosition.id,
          assetId: debtPosition.assetId,
          amountUsd6: parseFixed(repay.amountUsd.toFixed(6), 6),
          // Accrue to now so a full repay covers the interest since the last write.
          at: Date.now(),
        })
      } else if (kind === "claim") {
        const positions = resolveClaimPositions(session, walletId, marketId)
        const selections = selectionsFromPositions(positions)
        const claimPreview = buildHomeClaimPreview(session.state, walletId, positions, selections, safeAmount || null)
        const action = buildClaimBorrowAction(walletId, claimPreview)
        if (!action) throw new Error("Nothing to claim")
        intent = session.createIntent(action)
      } else {
        const position = session.state.accounts[walletId]?.collateralPositions.find(
          (entry) => entry.marketId === marketId,
        )
        if (!position) throw new Error("No collateral selected")
        intent = session.createIntent({
          type: "removeCollateral",
          walletId,
          positionId: position.id,
          percentBps: parseActionPercentBps(percent) ?? 0,
        })
      }

      const preview = await session.previewTransaction(intent)
      if (!preview.allowed) throw new Error(humanizeBlockedReason(preview.validationErrors[0]) ?? "Action unavailable")

      let executionPreviewUi = submittedPreviewUi
      if (kind === "borrow") {
        const token = session
          .getBorrowableAssetsForMarket(activeMarketId)
          .find((entry) => entry.id === resolvedBorrowAssetId)
        const borrowMarket = session.state.markets[activeMarketId]
        const maxBorrowUsd = usd6ToNumber(preview.before.availableBorrowCapacityUsd6)
        const priceUsd = usd6ToNumber(session.state.assets[resolvedBorrowAssetId ?? ""]?.snapshot.priceUsd6 ?? 0n)
        executionPreviewUi = mapBorrowTransactionPreviewToActionUi(preview, {
          symbol: token?.symbol ?? "Asset",
          amountUsd: priceUsd > 0 ? safeAmount * priceUsd : safeAmount,
          priceUsd,
          marketLabel,
          ratePct: token?.borrowApr ?? 0,
          balanceLabel: "Available to borrow",
          balanceUsd: maxBorrowUsd,
          liquidationThresholdPct: borrowMarket
            ? wadToPercent(borrowMarket.riskConfig.liquidationThresholdWad)
            : undefined,
          maxBorrowUsd,
          creditScopeLabel: creditScopeLabel ?? undefined,
        })
      } else if (kind === "supply") {
        const supplyMarket = session.state.markets[marketId]
        const collateralFactorPct = supplyMarket ? wadToPercent(supplyMarket.riskConfig.collateralFactorWad) : 0
        const liquidationPct = supplyMarket ? wadToPercent(supplyMarket.riskConfig.liquidationThresholdWad) : 0
        const borrowableAssets = session.getBorrowableAssetsForMarket(marketId)
        const walletBalanceUsd = usd6ToNumber(session.state.accounts[walletId]?.walletLpBalancesUsd6[marketId] ?? 0n)
        executionPreviewUi = mapBorrowSupplyPreviewToActionUi(preview, {
          symbol: formatBorrowLpSymbolLabel(supplyMarket),
          amountUsd: safeAmount,
          marketLabel,
          poolLabel: supplyMarket?.display.name ?? marketLabel,
          collateralSymbol: supplyMarket?.display.visuals[0]?.symbol ?? "LP",
          borrowSymbol: supplyMarket?.display.visuals[1]?.symbol ?? "",
          collateralFactorPct,
          collateralRiskPct: Math.max(0, liquidationPct - collateralFactorPct),
          borrowableAssetsLabel: borrowableAssets.map((asset) => asset.symbol).join(", ") || "—",
          borrowableAssetSymbols: borrowableAssets.map((asset) => asset.symbol),
          creditScopeLabel: creditScopeLabel ?? undefined,
          walletBalanceUsd,
        })
      } else if (kind === "repay" && debtPosition) {
        const repay = repayUsdForTokenAmount(session.state, debtPosition.assetId, safeAmount)
        if (!repay) throw new Error("Missing repay-asset price")
        const { priceUsd: repayPriceUsd, amountUsd: repayAmountUsd } = repay
        const repayModel = buildRepayPreviewModel(session.state, walletId, debtPosition.id, repayAmountUsd)
        executionPreviewUi = mapBorrowRepayPreviewToActionUi(preview, {
          symbol: session.state.assets[debtPosition.assetId]?.symbol ?? "Asset",
          amountUsd: repayAmountUsd,
          priceUsd: repayPriceUsd,
          marketLabel,
          remainingDebtUsd: repayModel.remainingDebtUsd,
          yearlyInterestSavedUsd: repayModel.yearlyInterestSavedUsd,
          creditScopeLabel: creditScopeLabel ?? undefined,
          exceedsDebt: repayModel.exceedsDebt,
        })
      } else if (kind === "remove") {
        const pct = (parseActionPercentBps(percent) ?? 0) / 100
        const removeModel = buildWithdrawPreviewModel(session.state, walletId, marketId, pct)
        executionPreviewUi = mapBorrowRemovePreviewToActionUi(preview, {
          percent: pct,
          safePercent: removeModel.safePercent,
          removeUsd: removeModel.removeUsd,
          marketLabel,
          positionApyPct: session.collateralPools.find((entry) => entry.id === marketId)?.pairApr ?? 0,
          creditScopeLabel: creditScopeLabel ?? undefined,
        })
      }

      const simulated = session.readAdapter.mode === "sandbox"
      const result = await runActionSubmitFlow({
        simulated,
        needsAllowance: false,
        onStage: setStage,
        execute: async () => session.executeTransaction(preview.intent),
      })

      if (result.receipt.status !== "success")
        throw new Error(humanizeBlockedReason(result.receipt.error) ?? "Transaction failed")
      const executedAmountUsd = usd6ToNumber(result.historyItem.executedAmountUsd6)
      const executedPreview = {
        ...executionPreviewUi,
        amountUsd: executedAmountUsd,
        amountUsdLabel: formatActionUsd(executedAmountUsd, { exact: true }),
      }

      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: `${descriptor.primaryVerb} successful`,
          // Always exact so tiny pledge amounts never render as a truncated "$0." fragment.
          description: `${formatActionUsd(executedAmountUsd, { exact: true })} processed.`,
          receiptHash: result.receipt.hash ?? null,
          metrics: executionPreviewUi.metrics,
          href: dashboardHrefForProduct("borrow"),
          primaryCtaLabel: successDashboardCtaLabel("borrow"),
          preview: executedPreview,
          verb: descriptor.primaryVerb,
        }),
      )
      setStage("success")
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Transaction was cancelled"
      // Keep the raw backend code (UNAUTHENTICATED / WALLET_MISMATCH / RATE_LIMITED / …)
      // in logs only; users see plain-language copy.
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
    activeMarketId,
    amount,
    closeHref,
    debtPosition,
    descriptor.primaryVerb,
    isPending,
    kind,
    marketId,
    percent,
    previewUi,
    resolvedBorrowAssetId,
    reviewPreviewUi,
    router,
    session,
    stage,
    successUi,
    walletId,
  ])

  // Borrow fills the safe credit cap; Repay fills the selected debt exactly.
  const showActionMax = kind === "borrow" || kind === "repay"
  const handleActionMax = useCallback(() => {
    // Repay can fill Max before a preview exists, so fall back to the outstanding debt.
    const max = previewUi?.maxAmount ?? repayDebtHint?.maxTokens ?? null
    if (max == null || max <= 0) return
    // Borrow's max is a TOKEN quantity (capacity ÷ price) and repay's is the exact
    // debt; floor both to 6 dp so the fill never rounds above the available
    // capacity/debt and trips "insufficient".
    const next = Math.floor(max * 1e6) / 1e6
    setAmount(String(next))
  }, [previewUi?.maxAmount, repayDebtHint?.maxTokens])

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

  const shellSubtitle =
    stage === "select"
      ? kind === "repay"
        ? "Choose the debt to repay."
        : kind === "claim"
          ? "Choose rewards to claim."
          : kind === "remove"
            ? "Choose collateral to remove."
            : kind === "supply"
              ? "Choose the LP pool you want to pledge."
              : "Choose the asset to borrow."
      : stage === "success" || isSubmittingStage(stage) || stage === "review"
        ? undefined
        : descriptor.subtitle
  const hideTitle = embedded || stage === "success" || isSubmittingStage(stage) || stage === "review"
  const isHomeLayout = embedded && layout === "home"
  const shellDensity = sidebar ? "sidebar" : isHomeLayout ? "home" : "default"
  // Require a collateral pool before the borrow-asset picker opens, so the asset
  // list is always scoped to the selected market (wallet-connection gating is
  // already enforced upstream by the sandbox/connect onboarding flow).
  const borrowNeedsCollateral = isHomeLayout && kind === "borrow" && !activeMarketId
  const useDialogAssetPicker = kind === "borrow" || kind === "repay"
  const pickerTokens = kind === "borrow" ? borrowTokens : kind === "repay" ? repayTokens : undefined
  const pickerSelectedTokenId =
    kind === "borrow"
      ? resolvedBorrowAssetId || assetId
      : kind === "repay"
        ? (debtPosition?.assetId ?? assetId)
        : kind === "claim"
          ? claimPositionId
          : kind === "supply"
            ? marketId
            : assetId
  const useSupplyWorkspace =
    embedded && isHomeLayout && kind === "supply" && activePool != null && isConfigureVisibleStage(stage)
  const useWorkspaceFields =
    embedded && isHomeLayout && (showCollateralContextBar || (kind === "supply" && activePool != null))
  const stackedAmountField =
    useWorkspaceFields && isConfigureVisibleStage(stage) && kind !== "claim" ? (
      kind === "remove" ? (
        <ActionLeverageRuler
          value={percent}
          onChange={setPercent}
          min={0}
          max={100}
          step={1}
          label="Percentage to remove"
          valueSuffix="%"
          subvalue={previewUi ? `Estimated removal · ${previewUi.amountUsdLabel}` : undefined}
          variant="embedded"
        />
      ) : (
        <ActionConfigureAmountSection
          verb={descriptor.primaryVerb}
          amount={amount}
          onAmountChange={setAmount}
          preview={previewUi}
          assetSymbol={assetSymbol}
          borrowSymbol={undefined}
          assetOptions={kind === "borrow" ? borrowAssetOptions : kind === "repay" ? repayAssetOptions : undefined}
          selectedAssetId={pickerSelectedTokenId}
          onAssetSelect={(id) => {
            if (kind === "repay") {
              const position =
                debtPositions.find((entry) => entry.id === id) ??
                debtPositions.find((entry) => entry.assetId === id && entry.marketId === marketId)
              if (!position) return
              setDebtPositionId(position.id)
              if (position.marketId) setMarketId(position.marketId)
              setAmount("")
              return
            }
            const selection = resolveBorrowTokenSelection(session, id, selectMarketId)
            if (!selection) return
            setAssetId(selection.assetId)
            setMarketId(selection.marketId)
            setAmount("")
          }}
          amountVariant="inset"
          hideAssetSelector={kind === "supply"}
          assetPickerVariant={useDialogAssetPicker ? "dialog" : "menu"}
          pickerTokens={useDialogAssetPicker ? pickerTokens : undefined}
          assetPickerDisabled={borrowNeedsCollateral}
          showBalance={showActionMax}
          balanceLabel={repayDebtHint ? "Outstanding debt" : undefined}
          balanceValue={previewUi ? undefined : repayDebtHint?.valueLabel}
          onMax={showActionMax ? handleActionMax : undefined}
        />
      )
    ) : null

  return (
    <ActionPageShell
      mode={embedded ? "embedded" : "page"}
      density={shellDensity}
      title={descriptor.title}
      subtitle={shellSubtitle}
      hideTitle={hideTitle}
      hideClose={embedded}
      closeHref={closeHref}
      flowHeaderStage={!embedded ? stage : undefined}
    >
      {useSupplyWorkspace && activePool ? (
        <ActionBorrowContextBar
          kind="supply"
          pool={activePool}
          pools={collateralPoolOptions}
          debts={debts}
          onPoolChange={(poolId) => {
            setMarketId(poolId)
            setAmount("")
          }}
          variant="inset"
          amountField={stackedAmountField}
          switchable={!initialMarketId && Boolean(supplyAssetOptions) && (stage === "configure" || stage === "error")}
        />
      ) : showCollateralContextBar ? (
        <ActionBorrowContextBar
          kind={kind}
          pool={activePool}
          pools={collateralPoolOptions}
          debts={debts}
          onPoolChange={handlePoolChange}
          variant={useWorkspaceFields ? "inset" : "card"}
          workspace={useWorkspaceFields}
          amountField={stackedAmountField}
          // Locked from Review on: the quote was built for this collateral, and switching it there
          // left Review showing a quote for the old pool.
          switchable={!(sidebar && kind === "claim") && (stage === "configure" || stage === "error")}
        />
      ) : null}

      {stage === "select" && !embedded ? (
        <ActionSelectStage
          items={selectItems}
          sectionLabel={
            kind === "supply" ? "Supported pools" : kind === "remove" ? "Your collateral" : "Available assets"
          }
          searchPlaceholder={kind === "supply" || kind === "remove" ? "Search pools" : "Find an asset"}
          emptyTitle={
            kind === "repay"
              ? "No debt found"
              : kind === "claim"
                ? "Nothing to claim"
                : kind === "remove"
                  ? "No collateral found"
                  : kind === "supply"
                    ? "No pools found"
                    : "No assets found"
          }
          emptyDescription={
            kind === "repay"
              ? "Borrow first, then repay from here."
              : kind === "claim"
                ? "You have no claimable rewards right now. Supply collateral and earn fees before claiming."
                : kind === "remove"
                  ? "Pledge collateral before trying to remove it."
                  : kind === "supply"
                    ? "No unpledged LP collateral is available in this wallet."
                    : "Try adjusting your search"
          }
          onSelect={(id) => {
            if (kind === "repay") {
              const position = debtPositions.find((entry) => entry.id === id)
              if (!position) return
              setDebtPositionId(position.id)
              if (position.marketId) setMarketId(position.marketId)
              setStage("configure")
              router.replace(
                actionPagePath("borrow", "repay", {
                  debt: id,
                  ...(position.marketId ? { market: position.marketId } : {}),
                }),
              )
              return
            }
            if (kind === "claim") {
              const claimItem = session.state.accounts[walletId]?.rewardPositions.find((entry) => entry.id === id)
              if (!claimItem) return
              setClaimPositionId(id)
              setMarketId(resolveClaimMarketId(claimItem.marketId))
              setStage("configure")
              router.replace(
                actionPagePath("borrow", "claim", {
                  position: id,
                  market: resolveClaimMarketId(claimItem.marketId),
                }),
              )
              return
            }
            if (kind === "supply") {
              setMarketId(id)
              setStage("configure")
              router.replace(actionPagePath("borrow", "supply", { market: id }))
              return
            }
            if (kind === "remove") {
              setMarketId(id)
              setPercent("25")
              setStage("configure")
              router.replace(actionPagePath("borrow", "remove", { market: id }))
              return
            }
            const selection = resolveBorrowTokenSelection(session, id, selectMarketId)
            router.replace(
              actionPagePath("borrow", "borrow", {
                asset: selection?.assetId ?? id,
                ...(selection?.marketId ? { market: selection.marketId } : {}),
              }),
            )
          }}
        />
      ) : null}

      {isSubmittingStage(stage) ? (
        <ActionProcessingStage
          verb={descriptor.primaryVerb}
          preview={reviewPreviewUi ?? previewUi}
          closeHref={closeHref}
          stage={stage}
        />
      ) : null}

      {stage === "review" && reviewPreviewUi ? (
        <ActionReviewStage
          title={reviewStageTitle(descriptor.primaryVerb)}
          subtitle="Confirm the details below before signing."
          hideHeader={embedded}
          preview={reviewPreviewUi}
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
          amount={kind === "remove" ? percent : amount}
          onAmountChange={kind === "remove" ? setPercent : setAmount}
          inputLabel={kind === "remove" ? "Percentage to remove" : undefined}
          preview={previewUi}
          emptyReason={kind === "repay" && !debtPosition ? "Nothing to repay" : undefined}
          // Pass the base COLLATERAL symbol (visuals[0]) for the ICON — not the pool display
          // name ("WETH / USDC"), which made the left bubble render pair-initials ("WU") instead
          // of the WETH icon on the Pledge/supply amount card. The pill TEXT keeps the pair
          // label via assetLabel so only the icon changes. Mirrors `remove`.
          assetSymbol={supplyPairSymbols ? supplyPairSymbols[0] : assetSymbol}
          assetLabel={kind === "supply" ? assetSymbol : undefined}
          borrowSymbol={supplyPairSymbols?.[1]}
          assetOptions={
            kind === "borrow"
              ? borrowAssetOptions
              : kind === "repay"
                ? repayAssetOptions
                : kind === "claim"
                  ? claimAssetOptions
                  : kind === "supply"
                    ? supplyAssetOptions
                    : undefined
          }
          selectedAssetId={pickerSelectedTokenId}
          onAssetSelect={(id) => {
            if (kind === "repay") {
              const position =
                debtPositions.find((entry) => entry.id === id) ??
                debtPositions.find((entry) => entry.assetId === id && entry.marketId === marketId)
              if (!position) return
              setDebtPositionId(position.id)
              if (position.marketId) setMarketId(position.marketId)
              setAmount("")
              return
            }
            if (kind === "claim") {
              const claimItem = session.state.accounts[walletId]?.rewardPositions.find((entry) => entry.id === id)
              if (!claimItem) return
              setClaimPositionId(id)
              setMarketId(resolveClaimMarketId(claimItem.marketId))
              setAmount("")
              setStage("configure")
              return
            }
            if (kind === "supply") {
              setMarketId(id)
              setAmount("")
              setStage("configure")
              return
            }
            const selection = resolveBorrowTokenSelection(session, id, selectMarketId)
            if (!selection) return
            setAssetId(selection.assetId)
            setMarketId(selection.marketId)
            setAmount("")
          }}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          secondaryHref={canGoBackToSelect ? undefined : closeHref}
          canGoBack={canGoBackToSelect}
          isPending={isPending}
          outcome={outcome}
          hideAmountInput={kind === "claim" || kind === "remove" || Boolean(useWorkspaceFields)}
          amountPlacement={useWorkspaceFields ? "stacked" : "inline"}
          multiplier={kind === "remove" ? percent : undefined}
          onMultiplierChange={kind === "remove" ? setPercent : undefined}
          multiplierMin={kind === "remove" ? 0 : undefined}
          multiplierMax={kind === "remove" ? 100 : undefined}
          multiplierStep={kind === "remove" ? 1 : undefined}
          multiplierLabel={kind === "remove" ? "Percentage to remove" : undefined}
          multiplierValueSuffix={kind === "remove" ? "%" : undefined}
          multiplierSubvalue={
            kind === "remove" && previewUi ? `Estimated removal · ${previewUi.amountUsdLabel}` : undefined
          }
          showBalance={showActionMax}
          balanceLabel={repayDebtHint ? "Outstanding debt" : undefined}
          balanceValue={previewUi ? undefined : repayDebtHint?.valueLabel}
          onMax={showActionMax ? handleActionMax : undefined}
          amountUnitLabel={kind === "remove" ? "%" : undefined}
          homeLayout={isHomeLayout}
          singlePrimaryCta={sidebar}
          claimSummary={kind === "claim"}
          assetPickerVariant={useDialogAssetPicker ? "dialog" : "menu"}
          pickerTokens={useDialogAssetPicker ? pickerTokens : undefined}
        />
      ) : null}
    </ActionPageShell>
  )
}
